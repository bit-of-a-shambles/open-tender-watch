# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "digest"

module PublicContracts
  module EU
    class TedClient
      SOURCE_NAME = "TED — Tenders Electronic Daily"
      BASE_URL    = "https://api.ted.europa.eu"
      API_VERSION = "v3"

      DEFAULT_FIELDS = %w[
        publication-number
        procedure-identifier
        publication-date
        notice-type
        notice-title
        organisation-country-buyer
        organisation-name-buyer
        BT-105-Procedure
        BT-27-Procedure
        BT-27-Procedure-Currency
        main-classification-proc
        BT-5071-Procedure
      ].freeze

      # Notice types that are amendments or corrections to existing notices
      # and should not be imported as new contracts.
      SKIP_NOTICE_TYPES = %w[cor can-modifies].freeze

      # Maps TED ISO 3166-1 alpha-3 codes to alpha-2 used by the domain model
      COUNTRY_MAP = { "PRT" => "PT", "ESP" => "ES", "FRA" => "FR", "DEU" => "DE" }.freeze

      # TED API rate limits: ~10 req/min without key, ~50/min with key.
      # inter_page_delay paces call_all so consecutive pages don't trigger 429s.
      DEFAULT_INTER_PAGE_DELAY = 1.5  # seconds between paginated fetches
      DEFAULT_MAX_RETRIES      = 3
      # Iteration mode maximum records per request (API hard cap)
      MAX_SCROLL_LIMIT         = 250

      def initialize(config = {})
        @api_key            = config.fetch("api_key", ENV["TED_API_KEY"])
        @country_code       = config.fetch("country_code", "PRT")  # ISO 3166-1 alpha-3 for EQL queries
        @inter_page_delay   = config.fetch("inter_page_delay", DEFAULT_INTER_PAGE_DELAY).to_f
        @max_retries        = config.fetch("max_retries", DEFAULT_MAX_RETRIES).to_i
      end

      def country_code      = "EU"
      def source_name       = SOURCE_NAME
      def inter_page_delay  = @inter_page_delay

      def search(query:, page: 1, limit: 10, fields: DEFAULT_FIELDS)
        body = { query: query, fields: fields, page: page, limit: limit }
        post("/#{API_VERSION}/notices/search", body)
      end

      def portuguese_contracts(page: 1, limit: 10)
        notices_for_country("PRT", page: page, limit: limit)
      end

      def notices_for_country(country_code, keyword: nil, page: 1, limit: 10)
        q = "organisation-country-buyer=#{country_code}"
        q += " AND #{keyword}" if keyword
        search(query: q, page: page, limit: limit)
      end

      # Fetches contracts using TED's scroll/iteration mode, which has no
      # 15 000-record pagination cap (unlike the regular page-based search).
      #
      # Maintains @scroll_token and @scroll_exhausted across calls so that
      # ImportService#call_all can drive pagination with incrementing page numbers
      # without knowing about the token internals:
      #   page == 1  → resets state and starts a fresh scroll
      #   page > 1   → continues from the stored token
      #   no token   → returns [] to signal end-of-results
      def fetch_contracts(page: 1, limit: MAX_SCROLL_LIMIT)
        if page == 1
          @scroll_token     = nil
          @scroll_exhausted = false
        end

        return [] if @scroll_exhausted

        body = {
          query:          "organisation-country-buyer=#{@country_code}",
          fields:         DEFAULT_FIELDS,
          limit:          [ limit, MAX_SCROLL_LIMIT ].min,
          paginationMode: "ITERATION"
        }
        body[:iterationNextToken] = @scroll_token if @scroll_token

        result = post("/#{API_VERSION}/notices/search", body)
        return [] unless result

        notices = Array(result["notices"])
        @scroll_token     = result["iterationNextToken"]
        @scroll_exhausted = @scroll_token.nil?

        notices.filter_map { |notice| normalize(notice) }
      end

      def total_count
        result = search(query: "organisation-country-buyer=#{@country_code}", limit: 1)
        result&.dig("totalNoticeCount") || 0
      end

      private

      # Maps a raw TED notice hash to the format ImportService expects.
      # TED notices don't carry buyer NIFs in the basic API fields, so we derive
      # a deterministic synthetic identifier from the buyer name to allow
      # deduplication across notices from the same organisation.
      #
      # Actual TED v3 field shapes:
      #   organisation-name-buyer   → {"eng" => ["Org Name"], ...}
      #   organisation-country-buyer → ["PRT"]
      #   notice-title              → {"eng" => "Portugal – ...", "por" => "...", ...}
      def normalize(notice)
        notice_type = notice["notice-type"].to_s.downcase
        return nil if SKIP_NOTICE_TYPES.include?(notice_type)

        buyer_name = extract_buyer_name(notice["organisation-name-buyer"])
        buyer_id   = "TED-#{Digest::MD5.hexdigest(buyer_name.downcase.strip)[0, 12]}"
        alpha3     = Array(notice["organisation-country-buyer"]).first.to_s
        iso2       = COUNTRY_MAP.fetch(alpha3, "EU")

        {
          "external_id"        => notice["procedure-identifier"].presence || notice["publication-number"],
          "country_code"       => iso2,
          "object"             => extract_title(notice["notice-title"]),
          "publication_date"   => notice["publication-date"]&.delete_suffix("Z"),
          "procedure_type"     => notice["BT-105-Procedure"],
          "base_price"         => notice["BT-27-Procedure"]&.then { |v| BigDecimal(v) },
          "cpv_code"           => Array(notice["main-classification-proc"]).first,
          "location"           => Array(notice["BT-5071-Procedure"]).first,
          "contracting_entity" => {
            "tax_identifier" => buyer_id,
            "name"           => buyer_name,
            "is_public_body" => true
          },
          "winners" => []
        }
      end

      # organisation-name-buyer is {"eng" => ["Name"], ...}. Prefer English,
      # fall back to first available language, then first element of the array.
      def extract_buyer_name(field)
        return "Unknown" unless field.is_a?(Hash)
        names = field["eng"] || field.values.first || []
        Array(names).first.presence || "Unknown"
      end

      # notice-title is {"eng" => "...", "por" => "...", ...}. Prefer English,
      # fall back to Portuguese, then first available language.
      # TED prepends the country name(s) to the title, e.g.:
      #   "Portugal \u2013 CPV description \u2013 Actual contract title"
      # We strip the leading country segment (everything before the first \u2013).
      def extract_title(field)
        return nil unless field.is_a?(Hash)
        title = field["eng"] || field["por"] || field.values.first
        return title unless title.is_a?(String) && title.include?(" \u2013 ")
        parts = title.split(" \u2013 ")
        parts.length > 1 ? parts.drop(1).join(" \u2013 ") : title
      end

      def post(path, body, attempt: 1)
        uri  = URI("#{BASE_URL}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = true
        http.open_timeout = 15
        http.read_timeout = 60

        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Accept"]       = "application/json"
        request["api-key"]      = @api_key if @api_key
        request.body            = body.to_json

        response = http.request(request)

        case response
        when Net::HTTPSuccess
          JSON.parse(response.body)
        else
          if response.code.to_i == 429 && attempt <= @max_retries
            wait = response["Retry-After"]&.to_i || 10
            rails_log("[TedClient] Rate limited (429). Waiting #{wait}s (attempt #{attempt}/#{@max_retries})")
            rate_limit_wait(wait)
            post(path, body, attempt: attempt + 1)
          else
            log_error(response)
            nil
          end
        end
      rescue StandardError => e
        log_exception(e)
        nil
      end

      # Separated from sleep so tests can stub without affecting Kernel
      def rate_limit_wait(seconds)
        sleep seconds
      end

      def log_error(response)
        rails_log("[TedClient] HTTP #{response.code}: #{response.message}")
      end

      def log_exception(error)
        rails_log("[TedClient] #{error.class}: #{error.message}")
      end

      def rails_log(msg)
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.error msg
        else
          warn msg
        end
      end
    end
  end
end
