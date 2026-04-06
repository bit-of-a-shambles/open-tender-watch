# Warms the Rails cache for the dashboard's cheap, fast queries.
# The expensive aggregates (entity exposure, totals) are pre-computed into
# flag_entity_stats / flag_summary_stats by the flags:aggregate rake task —
# this job no longer touches those tables at all.
#
# Scheduled hourly in config/recurring.yml; each run completes in < 5 seconds.
class DashboardStatsJob < ApplicationJob
  queue_as :default

  CACHE_TTL = 90.minutes

  def perform
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

    Rails.cache.write("dashboard/flag_type_severities",
                      Flag.group(:flag_type)
                          .select("flag_type, #{Flag.max_severity_sql} AS max_severity")
                          .each_with_object({}) { |r, h| h[r.flag_type] = r.max_severity },
                      expires_in: CACHE_TTL)

    Rails.cache.write("dashboard/active_sources_count",
                      DataSource.where(status: :active).count,
                      expires_in: CACHE_TTL)

    Rails.cache.write("dashboard/all_sources",
                      build_sources_list,
                      expires_in: CACHE_TTL)

    # Cache flag counts per severity (fast index lookups — < 100 ms each)
    [ nil, "high", "medium", "low" ].each do |sev|
      scope = sev ? Flag.where(severity: sev) : Flag.all
      Rails.cache.write("dashboard/flags_count/sev:#{sev}",   scope.count,                            expires_in: CACHE_TTL)
      Rails.cache.write("dashboard/flags_by_type/sev:#{sev}", scope.group(:flag_type).order(:flag_type).count, expires_in: CACHE_TTL)
    end

    # Pre-warm the most common entity-exposure views (unfiltered page 1, both
    # sort orders) so the first user after a data refresh never hits a cold cache.
    gen = Rails.cache.fetch("dashboard/entity_exposure/gen") { 0 }
    %w[value count].each do |sort|
      key = "dashboard/entity_exposure/g#{gen}/sort:#{sort}/flag:/sev:/page:1"
      Rails.cache.fetch(key, expires_in: 24.hours) do
        FlagEntityStat.exposure_rows(sort_by: sort, flag_type: nil, severity: nil, page: 1)
      end
    end
  end

  private

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
