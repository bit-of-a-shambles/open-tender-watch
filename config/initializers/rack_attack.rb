# frozen_string_literal: true

# Rack::Attack — rate limiting and request throttling.
#
# This app is public and read-heavy (civic transparency data). Limits are
# generous enough for legitimate browsing, aggregators, and journalists, but
# tight enough to prevent a single IP from saturating the 2GB VPS.
#
# Rules are evaluated in order. First match wins for `blocklist`/`throttle`.
# The `safelist` rules are checked first and bypass everything else.
#
# Test with:  curl -s -o /dev/null -w "%{http_code}" https://opentenderwatch.com
# Watch logs: grep "throttled\|blocked" <(rails logs -f)

class Rack::Attack
  # ---------------------------------------------------------------------------
  # Store — delegate to Rails.cache so we get SolidCache in production and
  # MemoryStore in test/development, with no extra configuration needed.
  # ---------------------------------------------------------------------------
  Rack::Attack.cache.store = Rails.cache

  # ---------------------------------------------------------------------------
  # Safelists — these IPs bypass all throttles.
  # Add your CI runner, monitoring probes, etc. here.
  # ---------------------------------------------------------------------------
  safelist("allow-localhost") do |req|
    req.ip == "127.0.0.1" || req.ip == "::1"
  end

  # ---------------------------------------------------------------------------
  # Real-IP helper — Cloudflare passes the actual visitor IP in CF-Connecting-IP.
  # Fall back to req.ip if the header is absent (direct connections / tests).
  # ---------------------------------------------------------------------------
  def self.real_ip(req)
    req.env["HTTP_CF_CONNECTING_IP"].presence || req.ip
  end

  # ---------------------------------------------------------------------------
  # Throttles — reads are generous (this is a public data service).
  # ---------------------------------------------------------------------------

  # General browsing: 120 req / 1 min per real IP.
  throttle("req/ip/1m", limit: 120, period: 1.minute) do |req|
    Rack::Attack.real_ip(req) unless req.path.start_with?("/assets", "/up")
  end

  # API-style pattern: same endpoint hammered repeatedly.
  # 30 req / 1 min per real IP per path.
  throttle("req/ip/path/1m", limit: 30, period: 1.minute) do |req|
    "#{Rack::Attack.real_ip(req)}:#{req.path}" unless req.path.start_with?("/assets", "/up")
  end

  # Export / heavy queries — contracts index with filters can be slow.
  throttle("contracts/ip/1m", limit: 20, period: 1.minute) do |req|
    Rack::Attack.real_ip(req) if req.path.start_with?("/contracts") && req.get?
  end

  # ---------------------------------------------------------------------------
  # Blocklists — permanently block known bad actors.
  # Add IPs via BLOCKED_IPS env var: BLOCKED_IPS="1.2.3.4,5.6.7.8"
  # ---------------------------------------------------------------------------
  blocklist("blocked-ips") do |req|
    blocked = ENV.fetch("BLOCKED_IPS", "").split(",").map(&:strip)
    blocked.include?(req.ip)
  end

  # ---------------------------------------------------------------------------
  # Response for throttled/blocked requests.
  # Plain text 429 is recognisable by scrapers; HTML body for browsers.
  # ---------------------------------------------------------------------------
  self.throttled_responder = lambda do |req|
    [
      429,
      {
        "Content-Type" => "text/plain",
        "Retry-After"  => "60"
      },
      [ "Too Many Requests — please slow down.\n" ]
    ]
  end

  self.blocklisted_responder = lambda do |_req|
    [ 403, { "Content-Type" => "text/plain" }, [ "Forbidden\n" ] ]
  end
end
