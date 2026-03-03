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

      SOURCE_NAME   = "Portal BASE"
      COUNTRY_CODE  = "PT"
      DADOS_GOV_API = "https://dados.gov.pt/api/1"
      DATASET_ID    = "66d72d488ca4b7cb2de28712"

      # Batch size for streaming rows out of the spreadsheet.
      # Keeps memory usage bounded — each batch is GC-able after processing.
      BATCH_SIZE = 500

      def initialize(config = {})
        super(DADOS_GOV_API)
        @years     = Array(config.fetch("years", Time.current.year))
        @resources = nil
      end

      def country_code = COUNTRY_CODE
      def source_name  = SOURCE_NAME

      # Returns an approximate total by summing last_row across all XLSX files.
      # Subtract 1 per file for the header row.
      def total_count
        resources = fetch_resources
        @years.sum do |year|
          res = resources.find { |r| resource_year(r) == year }
          next 0 unless res
          count_rows_in_resource(res["url"])
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
        Tempfile.create(["portal_base_count", ".xlsx"], binmode: true) do |tmp|
          download_file(url, tmp)
          tmp.flush
          xlsx = Roo::Spreadsheet.open(tmp.path)
          return [ xlsx.sheet(0).last_row - 1, 0 ].max
        end
      end

      # Streams rows one at a time from an XLSX resource, yielding each
      # normalised contract hash without accumulating all rows in memory.
      def stream_xlsx_resource(url)
        Tempfile.create(["portal_base", ".xlsx"], binmode: true) do |tmp|
          download_file(url, tmp)
          tmp.flush
          stream_spreadsheet(tmp.path) { |row| yield row }
        end
      end

      # rubocop:disable Security/Open
      def download_file(url, file)
        URI.open(url, "rb") { |remote| IO.copy_stream(remote, file) }
      end
      # rubocop:enable Security/Open

      def stream_spreadsheet(path)
        xlsx    = Roo::Spreadsheet.open(path)
        sheet   = xlsx.sheet(0)
        headers = sheet.row(1)
        (2..sheet.last_row).each do |i|
          row = normalize_row(headers, sheet.row(i))
          yield row if row
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

