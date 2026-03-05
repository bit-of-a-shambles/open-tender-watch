class DashboardController < ApplicationController
  include ActionView::Helpers::NumberHelper

  STATS_CACHE_TTL    = 15.minutes  # background job warms cache every 5 min
  EXPOSURE_ROW_LIMIT = 200

  def index
    @severity_filter  = params[:severity].presence
    @entity_sort      = params[:entity_sort] == "count" ? "count" : "value"
    @entity_flag_type = params[:entity_flag_type].presence

    # -----------------------------------------------------------------------
    # Stable counts — almost never change between requests, cache aggressively
    # -----------------------------------------------------------------------
    contract_count = Rails.cache.fetch("dashboard/contract_count", expires_in: STATS_CACHE_TTL) { Contract.count }
    entity_count   = Rails.cache.fetch("dashboard/entity_count",   expires_in: STATS_CACHE_TTL) { Entity.count }

    source_contract_counts = Rails.cache.fetch("dashboard/source_contract_counts", expires_in: STATS_CACHE_TTL) do
      Contract.where.not(data_source_id: nil).group(:data_source_id).count
    end

    entity_type_counts = Rails.cache.fetch("dashboard/entity_type_counts", expires_in: STATS_CACHE_TTL) do
      Entity.group(:is_public_body).count
    end

    @flag_types = Rails.cache.fetch("dashboard/flag_types", expires_in: STATS_CACHE_TTL) do
      Flag.distinct.order(:flag_type).pluck(:flag_type)
    end

    # -----------------------------------------------------------------------
    # Filter-dependent aggregates — cache per unique param combination.
    # Default (no filters) is the hot path; still cached like everything else.
    # -----------------------------------------------------------------------
    filter_key = "sev:#{@severity_filter}/ft:#{@entity_flag_type}/sort:#{@entity_sort}"

    aggregates = Rails.cache.fetch("dashboard/aggregates/#{filter_key}", expires_in: STATS_CACHE_TTL) do
      # ALWAYS start queries from flags (37K rows) — never from contracts (2.1M)
      # or entities (101K) or contract_winners (1.9M). SQLite processes joins
      # in declaration order; starting from the smallest table is critical.
      flags_scope = @severity_filter ? Flag.where(severity: @severity_filter) : Flag.all

      flags_count   = flags_scope.count
      flags_by_type = flags_scope.group(:flag_type).order(:flag_type).count

      # flags → contracts (via indexed contract_id)
      flagged_total_exposure  = flags_scope.joins(:contract).sum("contracts.base_price")
      flagged_contract_count  = flags_scope.distinct.count(:contract_id)

      # flags → contract_winners → entities  (all joins via indexed FKs)
      flagged_companies_count = flags_scope
        .joins(contract: { contract_winners: :entity })
        .where(entities: { is_company: true })
        .distinct
        .count("entities.id")

      # flags → contracts → contracting entity
      flagged_public_entities_count = flags_scope
        .joins(contract: :contracting_entity)
        .where(entities: { is_public_body: true })
        .distinct
        .count("contracts.contracting_entity_id")

      # Materialise the exposure rows into plain hashes so they survive Marshal
      # serialisation into Solid Cache (AR result objects cannot be marshalled).
      exposure_rows = entity_exposure_rows(
        sort_by:   @entity_sort,
        flag_type: @entity_flag_type,
        severity:  @severity_filter
      ).map { |r| { flag_type: r.flag_type, entity_name: r.entity_name,
                    exposure_value: r.exposure_value, exposure_count: r.exposure_count } }

      {
        flags_count:                   flags_count,
        flags_by_type:                 flags_by_type,
        flagged_total_exposure:        flagged_total_exposure,
        flagged_contract_count:        flagged_contract_count,
        flagged_companies_count:       flagged_companies_count,
        flagged_public_entities_count: flagged_public_entities_count,
        exposure_rows:                 exposure_rows
      }
    end

    @insights_count               = aggregates[:flags_count]
    @flags_by_type                = aggregates[:flags_by_type]
    @flagged_total_exposure       = aggregates[:flagged_total_exposure]
    @flagged_contract_count       = aggregates[:flagged_contract_count]
    @flagged_companies_count      = aggregates[:flagged_companies_count]
    @flagged_public_entities_count = aggregates[:flagged_public_entities_count]
    @entity_exposure_rows         = aggregates[:exposure_rows]

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
      { label: t("stats.contracts"), value: number_with_delimiter(contract_count),              color: "text-[#c8a84e]" },
      { label: t("stats.entities"),  value: number_with_delimiter(entity_count),                color: "text-[#e8e0d4]" },
      { label: t("stats.sources"),   value: active_sources_count.to_s,                          color: "text-[#e8e0d4]" },
      { label: t("stats.alerts"),    value: number_with_delimiter(@insights_count),             color: "text-[#ff4444]" }
    ]

    @sources = all_sources.map do |ds|
      {
        name:      ds[:name],
        country:   ds[:country_code],
        type:      ds[:source_type].capitalize,
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

  def entity_exposure_rows(sort_by:, flag_type:, severity: nil)
    scope = Flag.joins(contract: :contracting_entity)
    scope = scope.where(flag_type: flag_type) if flag_type.present?
    scope = scope.where(severity: severity) if severity.present?

    order_sql = sort_by == "count" \
      ? "exposure_count DESC, exposure_value DESC, entities.name ASC"
      : "exposure_value DESC, exposure_count DESC, entities.name ASC"

    scope.select(
      "flags.flag_type AS flag_type",
      "contracts.contracting_entity_id AS entity_id",
      "entities.name AS entity_name",
      "COALESCE(SUM(COALESCE(contracts.base_price, 0)), 0) AS exposure_value",
      "COUNT(DISTINCT contracts.id) AS exposure_count"
    ).group(
      "flags.flag_type, contracts.contracting_entity_id, entities.name"
    ).order(
      Arel.sql(order_sql)
    ).limit(EXPOSURE_ROW_LIMIT)
  end
end
