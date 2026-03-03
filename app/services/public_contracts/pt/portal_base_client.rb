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

      def initialize(config = {})
        super(DADOS_GOV_API)
        @years = Array(config.fetch("years", Time.current.year))
        @rows  = nil
      end

      def country_code = COUNTRY_CODE
      def source_name  = SOURCE_NAME

      def total_count
        all_rows.size
      end

      def fetch_contracts(page: 1, limit: 100)
        start = (page - 1) * limit
        all_rows[start, limit] || []
      end

      private

      def all_rows
        @rows ||= load_rows
      end

      def load_rows
        resources = fetch_resources
        @years.flat_map do |year|
          res = resources.find { |r| r["title"]&.downcase == "contratos#{year}.xlsx" }
          unless res
            Rails.logger.warn "[PortalBaseClient] No XLSX resource found for year #{year}"
            next []
          end
          parse_xlsx_resource(res["url"])
        end.compact
      end

      def fetch_resources
        result = get("/datasets/#{DATASET_ID}/")
        Array(result&.dig("resources")).select { |r| r["format"]&.downcase == "xlsx" }
      end

      def parse_xlsx_resource(url)
        rows = []
        Tempfile.create(["portal_base", ".xlsx"], binmode: true) do |tmp|
          download_file(url, tmp)
          tmp.flush
          rows = parse_spreadsheet(tmp.path)
        end
        rows
      end

      # rubocop:disable Security/Open
      def download_file(url, file)
        URI.open(url, "rb") { |remote| IO.copy_stream(remote, file) }
      end
      # rubocop:enable Security/Open

      def parse_spreadsheet(path)
        xlsx  = Roo::Spreadsheet.open(path)
        sheet = xlsx.sheet(0)
        headers = sheet.row(1)
        (2..sheet.last_row).filter_map { |i| normalize_row(headers, sheet.row(i)) }
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
          "object"                => h["objectoContrato"]&.strip,
          "procedure_type"        => h["tipoprocedimento"],
          "contract_type"         => h["tipoContrato"],
          "publication_date"      => parse_date(h["dataPublicacao"]),
          "celebration_date"      => parse_date(h["dataCelebracaoContrato"]),
          "base_price"            => parse_decimal(h["precoBaseProcedimento"]),
          "total_effective_price" => effective,
          "cpv_code"              => parse_cpv(h["CPV"]),
          "location"              => h["LocalExecucao"],
          "contracting_entity"    => contracting,
          "winners"               => parse_winners(h["adjudicatarios"])
        }
      end

      # Parse "504595067 - Entidade Pública, L.da"
      def parse_entity(raw)
        return nil if raw.blank?
        m = raw.strip.match(/\A(\d{6,11})\s*[-–]\s*(.+)\z/m)
        return nil unless m
        { "tax_identifier" => m[1], "name" => m[2].strip, "is_public_body" => true }
      end

      # Parse multi-line adjudicatarios: "NIF - Name\nNIF - [pos - ]Name"
      def parse_winners(raw)
        return [] if raw.blank?
        raw.to_s.split(/\r?\n/).filter_map do |line|
          m = line.strip.match(/\A(\d{6,11})\s*[-–]\s*(.+)\z/)
          next unless m
          # Strip optional leading position counter "1 - " from the name
          name = m[2].strip.sub(/\A\d+\s*[-–]\s*/, "")
          { "tax_identifier" => m[1], "name" => name, "is_company" => true }
        end
      end

      # "31720000-9 - Equipamento..." → "31720000"
      def parse_cpv(raw)
        return nil if raw.blank?
        raw.strip.split(/\s+/).first&.split("-")&.first
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

