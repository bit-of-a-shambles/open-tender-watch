# frozen_string_literal: true

module PublicContracts
  module PT
    # Fetches Portuguese public contracts from Portal BASE via the freely available
    # bulk XLSX files published daily by IMPIC on dados.gov.pt.
    #
    # Dataset: "Contratos Públicos - Portal Base - IMPIC - Contratos de 2012 a 2026"
    # https://dados.gov.pt/datasets/66d72d488ca4b7cb2de28712
    #
    # Configuration keys:
    #   years: [Integer, Array<Integer>]  — years to ingest (default: current year)
    class PortalBaseClient < PublicContracts::BaseClient
      require "tempfile"
      require "open-uri"
      require "roo"
      require "bigdecimal"
      require "fileutils"

      SOURCE_NAME   = "Portal BASE"
      COUNTRY_CODE  = "PT"
      CACHE_DIR     = Rails.root.join("tmp", "cache", "portal_base")
      DADOS_GOV_API = "https://dados.gov.pt/api/1"
      DATASET_ID    = "66d72d488ca4b7cb2de28712"

      # Batch size for streaming rows out of the spreadsheet.
      # Keeps memory usage bounded — each batch is GC-able after processing.
      BATCH_SIZE = 500

      # Rough estimate of compressed bytes per XLSX row (derived from 2026 sample:
      # 6.6 MB file → 27,484 rows ≈ 250 bytes/row). Used in total_count to avoid
      # downloading all files just to count rows.
      BYTES_PER_ROW_ESTIMATE = 250

      def initialize(config = {})
        super(DADOS_GOV_API)
        @years     = Array(config.fetch("years", Time.current.year))
        @resources = nil
      end

      def country_code = COUNTRY_CODE
      def source_name  = SOURCE_NAME

      # Returns an estimated total by summing filesize / BYTES_PER_ROW_ESTIMATE.
      # This avoids downloading all XLSX files just to count rows — an operation
      # that would consume ~485 MB of bandwidth and minutes of latency before
      # the import even starts.
      def total_count
        fetch_resources.sum do |res|
          next 0 unless @years.include?(resource_year(res))
          (res.fetch("filesize", 0).to_i / BYTES_PER_ROW_ESTIMATE).clamp(0, 10_000_000)
        end
      end

      # Downloads all configured year XLSX files to the disk cache without
      # processing any rows. Safe to call multiple times — already-cached files
      # are skipped. Yields progress lines if a block is given.
      def prefetch_files
        resources = fetch_resources.select { |r| @years.include?(resource_year(r)) }
                                   .sort_by { |r| resource_year(r) || 0 }
        FileUtils.mkdir_p(CACHE_DIR)
        resources.each do |res|
          year   = resource_year(res)
          cached = cached_xlsx_path(res["url"])
          if cached_xlsx_valid?(cached)
            size = (File.size(cached) / 1_048_576.0).round(1)
            yield "  #{year}: already cached (#{size} MB)" if block_given?
          else
            File.delete(cached) if File.exist?(cached) # remove any partial/0-byte file
            yield "  #{year}: downloading..." if block_given?
            t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            download_with_retry(res["url"], cached)
            elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).round(1)
            size    = (File.size(cached) / 1_048_576.0).round(1)
            yield "  #{year}: done (#{size} MB in #{elapsed}s)" if block_given?
          end
        end
      end

      # Single-pass streaming for bulk imports — downloads each year file exactly
      # once and yields every normalised contract hash in chronological order.
      # Unlike the paginated fetch_contracts, this never re-reads a file from the
      # start. Use this (via call_streaming) for imports; use fetch_contracts only
      # for targeted single-page fetches or adapters that must paginate.
      def each_contract
        return enum_for(:each_contract) unless block_given?

        fetch_resources.sort_by { |r| resource_year(r) || 0 }.each do |res|
          next unless @years.include?(resource_year(res))

          year = resource_year(res)
          Rails.logger.info "[PortalBaseClient] Streaming #{year} XLSX from #{res['url']}"
          stream_xlsx_resource(res["url"]) { |row| yield row }
        end
      end

      # Streams contracts in batches — never holds the full spreadsheet in RAM.
      # Yields (or returns) one page of BATCH_SIZE normalised hashes at a time.
      def fetch_contracts(page: 1, limit: BATCH_SIZE)
        resources = fetch_resources
        batch     = []
        offset    = (page - 1) * limit

        @years.each do |year|
          res = resources.find { |r| resource_year(r) == year }
          unless res
            Rails.logger.warn "[PortalBaseClient] No XLSX resource found for year #{year}"
            next
          end

          stream_xlsx_resource(res["url"]) do |row|
            offset > 0 ? (offset -= 1) : (batch << row)
            return batch if batch.size >= limit
          end
        end

        batch
      end

      private

      def resource_year(res)
        m = res["title"]&.downcase&.match(/contratos(\d{4})\.xlsx/)
        m ? m[1].to_i : nil
      end

      def fetch_resources
        @resources ||= begin
          result = get("/datasets/#{DATASET_ID}/")
          Array(result&.dig("resources")).select { |r| r["format"]&.downcase == "xlsx" }
        end
      end

      def count_rows_in_resource(url)
        cached = cached_xlsx_path(url)
        FileUtils.mkdir_p(CACHE_DIR)
        unless cached_xlsx_valid?(cached)
          File.delete(cached) if File.exist?(cached)
          download_with_retry(url, cached)
        end
        xlsx = Roo::Spreadsheet.open(cached)
        [ xlsx.sheet(0).last_row - 1, 0 ].max
      end

      # Streams rows one at a time from an XLSX resource, yielding each
      # normalised contract hash without accumulating all rows in memory.
      # Downloaded files are cached in tmp/cache/portal_base/ so that
      # subsequent runs (or restarts) skip the network download entirely.
      def stream_xlsx_resource(url)
        cached = cached_xlsx_path(url)
        FileUtils.mkdir_p(CACHE_DIR)
        unless cached_xlsx_valid?(cached)
          File.delete(cached) if File.exist?(cached) # remove any partial/0-byte file
          Rails.logger.info "[PortalBaseClient] Downloading #{url}"
          download_with_retry(url, cached)
        else
          Rails.logger.info "[PortalBaseClient] Cache hit: #{cached}"
        end
        stream_spreadsheet(cached.to_s) { |row| yield row }
      end

      def cached_xlsx_path(url)
        filename = URI.parse(url).path.split("/").last
        CACHE_DIR.join(filename)
      end

      def cached_xlsx_valid?(path)
        File.exist?(path) && File.size(path) > 0
      end

      # Retries up to 3 times on transient network errors, cleaning up any
      # partial file before each attempt so cache-validity checks stay correct.
      def download_with_retry(url, dest, attempts: 3)
        attempts.times do |i|
          File.open(dest, "wb") { |f| download_file(url, f) }
          return if cached_xlsx_valid?(dest)

          File.delete(dest) if File.exist?(dest)
          raise "Empty file after download: #{url}" if i == attempts - 1
        rescue Errno::ECONNRESET, EOFError, Net::ReadTimeout, OpenURI::HTTPError => e
          File.delete(dest) if File.exist?(dest)
          raise if i == attempts - 1

          Rails.logger.warn "[PortalBaseClient] Download error (attempt #{i + 1}): #{e.message} — retrying"
          sleep(2 ** i) # 1s, 2s back-off
        end
      end

      # rubocop:disable Security/Open
      def download_file(url, file)
        URI.open(url, "rb") { |remote| IO.copy_stream(remote, file) }
      end
      # rubocop:enable Security/Open

      # Uses Roo's SAX-based each_row_streaming to avoid loading the full
      # spreadsheet into memory. Roo streams cells one row at a time.
      def stream_spreadsheet(path)
        xlsx    = Roo::Spreadsheet.open(path)
        headers = nil
        xlsx.each_row_streaming(pad_cells: true) do |cells|
          values = cells.map { |c| c&.value }
          if headers.nil?
            headers = values
          else
            row = normalize_row(headers, values)
            yield row if row
          end
        end
      end

      # Keep parse_spreadsheet for test stubbing convenience
      def parse_spreadsheet(path)
        rows = []
        stream_spreadsheet(path) { |r| rows << r }
        rows
      end

      def normalize_row(headers, values)
        h = headers.zip(values).to_h
        contracting = parse_entity(h["adjudicante"])
        return nil unless contracting

        effective = parse_decimal(h["PrecoTotalEfetivo"])
        # Fall back to contractual price when effective is zero (contract still running)
        effective = parse_decimal(h["precoContratual"]) if effective.nil? || effective.zero?

        {
          "external_id"           => h["idcontrato"]&.to_s,
          "country_code"          => COUNTRY_CODE,
          "object"                => h["objectoContrato"]&.to_s&.strip,
          "procedure_type"        => h["tipoprocedimento"]&.to_s,
          "contract_type"         => h["tipoContrato"]&.to_s,
          "publication_date"      => parse_date(h["dataPublicacao"]),
          "celebration_date"      => parse_date(h["dataCelebracaoContrato"]),
          "base_price"            => parse_decimal(h["precoBaseProcedimento"]),
          "total_effective_price" => effective,
          "cpv_code"              => parse_cpv(h["CPV"]),
          "location"              => h["LocalExecucao"]&.to_s,
          "contracting_entity"    => contracting,
          "winners"               => parse_winners(h["adjudicatarios"])
        }
      end

      # Parse "504595067 - Entidade Pública, L.da"
      def parse_entity(raw)
        str = raw.to_s.strip
        return nil if str.blank?
        m = str.match(/\A(\d{6,11})\s*[-–]\s*(.+)\z/m)
        return nil unless m
        { "tax_identifier" => m[1], "name" => m[2].strip, "is_public_body" => true }
      end

      # Parse multi-line adjudicatarios: "NIF - Name\nNIF - [pos - ]Name"
      def parse_winners(raw)
        str = raw.to_s.strip
        return [] if str.blank?
        str.split(/\r?\n/).filter_map do |line|
          m = line.strip.match(/\A(\d{6,11})\s*[-–]\s*(.+)\z/)
          next unless m
          # Strip optional leading position counter "1 - " from the name
          name = m[2].strip.sub(/\A\d+\s*[-–]\s*/, "")
          { "tax_identifier" => m[1], "name" => name, "is_company" => true }
        end
      end

      # "31720000-9 - Equipamento..." → "31720000"
      def parse_cpv(raw)
        str = raw.to_s.strip
        return nil if str.blank?
        str.split(/\s+/).first&.split("-")&.first
      end

      def parse_date(value)
        return nil if value.blank?
        value.to_date
      rescue ArgumentError, TypeError, NoMethodError
        nil
      end

      def parse_decimal(value)
        return nil if value.nil?
        v = value.is_a?(Float) ? value.to_i : value
        BigDecimal(v.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
