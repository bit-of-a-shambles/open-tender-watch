# frozen_string_literal: true

# Pre-aggregated entity exposure, one row per (entity, flag_type, severity).
# Populated by the flags:aggregate rake task — never computed on-demand.
# The dashboard reads from this table instead of joining across 2M+ flags at runtime.
class FlagEntityStat < ApplicationRecord
  belongs_to :entity

  validates :flag_type,     presence: true
  validates :severity,      presence: true
  validates :contract_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :computed_at,   presence: true

  PER_PAGE = 50

  # Groups across severity variants so the unfiltered view shows one row per
  # entity+flag combination. Returns [rows_array, total_count, total_pages].
  def self.exposure_rows(sort_by:, flag_type:, severity:, page:)
    scope = joins(:entity)
    scope = scope.where(flag_type: flag_type) if flag_type.present?
    scope = scope.where(severity:  severity)  if severity.present?

    order_col = sort_by == "count" ? "exposure_count" : "exposure_value"

    base = scope
      .select(
        "flag_entity_stats.flag_type             AS flag_type",
        "flag_entity_stats.entity_id             AS entity_id",
        "entities.name                           AS entity_name",
        "SUM(flag_entity_stats.total_exposure)   AS exposure_value",
        "SUM(flag_entity_stats.contract_count)   AS exposure_count"
      )
      .group("flag_entity_stats.flag_type, flag_entity_stats.entity_id, entities.name")

    total = connection.select_value("SELECT COUNT(*) FROM (#{base.to_sql}) AS sub").to_i
    pages = [ (total.to_f / PER_PAGE).ceil, 1 ].max

    rows = base
      .order(Arel.sql("#{order_col} DESC, entities.name ASC"))
      .limit(PER_PAGE)
      .offset((page - 1) * PER_PAGE)
      .map { |r| { flag_type: r.flag_type, entity_id: r.entity_id, entity_name: r.entity_name,
                   exposure_value: r.exposure_value.to_f, exposure_count: r.exposure_count.to_i } }

    [ rows, total, pages ]
  end
end
