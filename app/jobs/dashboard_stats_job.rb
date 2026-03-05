# Pre-computes all dashboard aggregates and writes them to the Rails cache.
# Scheduled by Solid Queue to run every 5 minutes so that user requests
# almost always hit a warm cache and never trigger the heavy queries inline.
class DashboardStatsJob < ApplicationJob
  queue_as :default

  CACHE_TTL = 15.minutes

  def perform
    # -----------------------------------------------------------------------
    # Stable counts — shared cache keys with the dashboard controller
    # -----------------------------------------------------------------------
    Rails.cache.write("dashboard/contract_count",
                      Contract.count, expires_in: CACHE_TTL)

    Rails.cache.write("dashboard/entity_count",
                      Entity.count, expires_in: CACHE_TTL)

    Rails.cache.write("dashboard/source_contract_counts",
                      Contract.where.not(data_source_id: nil).group(:data_source_id).count,
                      expires_in: CACHE_TTL)

    Rails.cache.write("dashboard/entity_type_counts",
                      Entity.group(:is_public_body).count,
                      expires_in: CACHE_TTL)

    Rails.cache.write("dashboard/flag_types",
                      Flag.distinct.order(:flag_type).pluck(:flag_type),
                      expires_in: CACHE_TTL)

    Rails.cache.write("dashboard/active_sources_count",
                      DataSource.where(status: :active).count,
                      expires_in: CACHE_TTL)

    Rails.cache.write("dashboard/all_sources",
                      build_sources_list,
                      expires_in: CACHE_TTL)

    # -----------------------------------------------------------------------
    # Default aggregates — hot path: no severity, no flag_type, sort by value
    # -----------------------------------------------------------------------
    Rails.cache.write(
      "dashboard/aggregates/sev:/ft:/sort:value",
      compute_aggregates(severity: nil, flag_type: nil, sort_by: "value"),
      expires_in: CACHE_TTL
    )
  end

  private

  def compute_aggregates(severity:, flag_type:, sort_by:)
    flags_scope      = severity ? Flag.where(severity: severity) : Flag.all
    flagged_subquery = flags_scope.select(:contract_id).distinct

    flags_count   = flags_scope.count
    flags_by_type = flags_scope.group(:flag_type).order(:flag_type).count

    flagged_total_exposure = Contract.where(id: flagged_subquery).sum(:base_price)
    flagged_contract_count = flagged_subquery.count

    flagged_companies_count = Entity
      .joins(contract_winners: { contract: :flags })
      .merge(flags_scope)
      .where(is_company: true)
      .distinct
      .count

    flagged_public_entities_count = Entity
      .joins(contracts_as_contracting_entity: :flags)
      .merge(flags_scope)
      .where(is_public_body: true)
      .distinct
      .count

    exposure_rows = compute_exposure_rows(sort_by: sort_by, flag_type: flag_type, severity: severity)
      .map { |r| { flag_type: r.flag_type, entity_name: r.entity_name,
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

  def compute_exposure_rows(sort_by:, flag_type:, severity:)
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
    ).limit(200)
  end

  def build_sources_list
    counts = Contract.where.not(data_source_id: nil).group(:data_source_id).count
    DataSource.order(:country_code, :name).map do |ds|
      { id: ds.id, name: ds.name, country_code: ds.country_code,
        source_type: ds.source_type, status: ds.status,
        records: counts.fetch(ds.id, 0),
        synced_at: ds.last_synced_at&.strftime("%Y-%m-%d %H:%M") }
    end
  end
end
