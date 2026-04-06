class DashboardController < ApplicationController
  include ActionView::Helpers::NumberHelper

  STATS_CACHE_TTL   = 60.minutes

  def index
    @severity_filter  = params[:severity].presence
    @entity_sort      = params[:entity_sort] == "count" ? "count" : "value"
    @entity_flag_type = params[:entity_flag_type].presence
    @entity_page      = [ params[:entity_page].to_i, 1 ].max

    # HTTP conditional GET — locale-aware ETag allows cheap 304 responses while
    # ensuring a locale change (session cookie) always triggers a fresh 200 response.
    # Cache-Control: private, no-cache (from stale? with public: false) forces the
    # browser to always conditional-GET before serving from cache, so locale switches
    # are reflected immediately. We deliberately avoid max-age: a browser-cached
    # max-age response would be served without contacting the server, breaking locale
    # switching within the cache window.
    last_agg = Rails.cache.fetch("dashboard/last_agg", expires_in: 60.seconds) { FlagSummaryStat.maximum(:computed_at) } || 1.hour.ago
    return unless stale?(last_modified: last_agg,
                         etag: [ last_agg.to_i, I18n.locale.to_s ],
                         public: false)

    # -----------------------------------------------------------------------
    # Stable counts — cheap queries, cache generously
    # -----------------------------------------------------------------------
    contract_count = Rails.cache.fetch("dashboard/contract_count", expires_in: STATS_CACHE_TTL) { Contract.count }
    entity_count   = Rails.cache.fetch("dashboard/entity_count",   expires_in: STATS_CACHE_TTL) { Entity.count }

    source_contract_counts = Rails.cache.fetch("dashboard/source_contract_counts", expires_in: STATS_CACHE_TTL) do
      Contract.where.not(data_source_id: nil).group(:data_source_id).count
    end

    entity_type_counts = Rails.cache.fetch("dashboard/entity_type_counts", expires_in: STATS_CACHE_TTL) do
      Entity.group(:is_public_body).count
    end

    # Flag type list — used to populate filter pills, cached for 1 h.
    @flag_types = Rails.cache.fetch("dashboard/flag_types", expires_in: STATS_CACHE_TTL) do
      Flag.distinct.order(:flag_type).pluck(:flag_type)
    end

    # Max severity per flag_type from the DB — canonical source used in insight cards.
    @flag_type_severities = Rails.cache.fetch("dashboard/flag_type_severities", expires_in: STATS_CACHE_TTL) do
      Flag.group(:flag_type)
          .select("flag_type, #{Flag.max_severity_sql} AS max_severity")
          .each_with_object({}) { |r, h| h[r.flag_type] = r.max_severity }
    end

    # Flag count + per-type breakdown — fast indexed queries, cached.
    flags_scope      = @severity_filter ? Flag.where(severity: @severity_filter) : Flag.all
    @insights_count  = Rails.cache.fetch("dashboard/flags_count/sev:#{@severity_filter}", expires_in: STATS_CACHE_TTL) { flags_scope.count }
    @flags_by_type   = Rails.cache.fetch("dashboard/flags_by_type/sev:#{@severity_filter}", expires_in: STATS_CACHE_TTL) do
      flags_scope.group(:flag_type).order(:flag_type).count
    end

    # -----------------------------------------------------------------------
    # Pre-computed aggregate totals — read from flag_summary_stats (single row
    # lookup), populated by flags:aggregate. Zero-fallback if not yet computed.
    # -----------------------------------------------------------------------
    summary = FlagSummaryStat.find_by(severity: @severity_filter)
    @flagged_total_exposure        = summary&.total_exposure || 0
    @flagged_contract_count        = summary&.flagged_contract_count || 0
    @flagged_companies_count       = summary&.flagged_companies_count || 0
    @flagged_public_entities_count = summary&.flagged_public_entities_count || 0

    # -----------------------------------------------------------------------
    # Entity exposure table — reads from flag_entity_stats (pre-aggregated),
    # never joins the flags table at request time.
    # -----------------------------------------------------------------------
    exposure_gen       = Rails.cache.fetch("dashboard/entity_exposure/gen") { 0 }
    exposure_cache_key = "dashboard/entity_exposure/g#{exposure_gen}/sort:#{@entity_sort}/flag:#{@entity_flag_type}/sev:#{@severity_filter}/page:#{@entity_page}"
    @entity_exposure_rows, @entity_total, @entity_total_pages = Rails.cache.fetch(exposure_cache_key, expires_in: 24.hours) do
      FlagEntityStat.exposure_rows(
        sort_by:   @entity_sort,
        flag_type: @entity_flag_type,
        severity:  @severity_filter,
        page:      @entity_page
      )
    end

    active_sources_count = Rails.cache.fetch("dashboard/active_sources_count", expires_in: STATS_CACHE_TTL) do
      DataSource.where(status: :active).count
    end

    all_sources = Rails.cache.fetch("dashboard/all_sources", expires_in: STATS_CACHE_TTL) do
      DataSource.order(:country_code, :name).map do |ds|
        { id: ds.id, name: ds.name, country_code: ds.country_code,
          source_type: ds.source_type, status: ds.status,
          records: source_contract_counts.fetch(ds.id, 0),
          synced_at: ds.last_synced_at&.strftime("%Y-%m-%d %H:%M") }
      end
    end

    @stats = [
      { label: t("stats.contracts"), value: number_with_delimiter(contract_count),  color: "text-[#c8a84e]" },
      { label: t("stats.entities"),  value: number_with_delimiter(entity_count),    color: "text-[#e8e0d4]" },
      { label: t("stats.sources"),   value: active_sources_count.to_s,              color: "text-[#e8e0d4]" },
      { label: t("stats.alerts"),    value: number_with_delimiter(@insights_count), color: "text-[#ff4444]" }
    ]

    @sources = all_sources.map do |ds|
      {
        name:      ds[:name],
        country:   ds[:country_code],
        type:      ds[:source_type],
        status:    ds[:status],
        records:   number_with_delimiter(ds[:records]),
        synced_at: ds[:synced_at]
      }
    end

    @crossings = [
      { label: t("dashboard.crossings.contracts_with_winners"), count: number_with_delimiter(entity_type_counts[false] || 0) },
      { label: t("dashboard.crossings.public_bodies"),          count: number_with_delimiter(entity_type_counts[true]  || 0) },
      { label: t("dashboard.crossings.ecfp_donors"),            count: "—" },
      { label: t("dashboard.crossings.tdc_sanctions"),          count: "—" }
    ]
  end

  private
end
