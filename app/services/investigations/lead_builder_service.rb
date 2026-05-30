# frozen_string_literal: true

module Investigations
  class LeadBuilderService
    DEFAULT_LIMIT = 24
    MAX_LIMIT = 100

    LEAD_TYPE_BY_FLAG = {
      "B2_SUPPLIER_CONCENTRATION" => "supplier_concentration",
      "A1_REPEAT_DIRECT_AWARD" => "repeat_direct_awards",
      "A5_THRESHOLD_SPLITTING" => "threshold_splitting",
      "A2_PUBLICATION_AFTER_CELEBRATION" => "late_publication",
      "A9_PRICE_ANOMALY" => "price_anomaly",
      "A9_PRICE_REDUCTION" => "price_anomaly",
      "C1_MISSING_WINNER_NIF" => "data_integrity",
      "C3_MISSING_MANDATORY_FIELDS" => "data_integrity"
    }.freeze

    LEAD_TYPE_PRIORITY = LEAD_TYPE_BY_FLAG.keys.freeze
    ALLOWED_LEAD_TYPES = (LEAD_TYPE_BY_FLAG.values + [ "multi_flag_risk" ]).uniq.freeze
    FLAG_TYPES_BY_LEAD_TYPE = LEAD_TYPE_BY_FLAG
      .each_with_object(Hash.new { |hash, key| hash[key] = [] }) { |(flag_type, lead_type), hash| hash[lead_type] << flag_type }
      .transform_values(&:freeze)
      .freeze

    SEVERITY_TO_SCORE = {
      "low" => 1,
      "medium" => 2,
      "high" => 3,
      "critical" => 4
    }.freeze

    SCORE_TO_SEVERITY = SEVERITY_TO_SCORE.invert.freeze

    def initialize(severity: nil, lead_type: nil, limit: DEFAULT_LIMIT)
      @severity = normalize_severity(severity)
      @lead_type = normalize_lead_type(lead_type)
      @limit = normalize_limit(limit)
    end

    def call
      entity_rows = ranked_entity_rows
      return empty_response if entity_rows.empty?

      details_by_entity = detail_rows_by_entity(entity_rows.map(&:entity_id))

      leads = entity_rows.filter_map do |row|
        details = details_by_entity.fetch(row.entity_id, [])
        build_lead(row, details)
      end

      {
        leads: leads.first(@limit),
        meta: {
          filters: {
            severity: @severity,
            lead_type: @lead_type
          },
          limit: @limit,
          candidate_count: leads.size
        }
      }
    end

    private

    def empty_response
      {
        leads: [],
        meta: {
          filters: {
            severity: @severity,
            lead_type: @lead_type
          },
          limit: @limit,
          candidate_count: 0
        }
      }
    end

    def scoped_stats
      scope = FlagEntityStat.joins(:entity)
      scope = scope.where(severity: @severity) if @severity.present?

      lead_type_entity_ids = lead_type_entity_scope
      scope = scope.where(entity_id: lead_type_entity_ids) if lead_type_entity_ids

      scope
    end

    def ranked_entity_rows
      query = scoped_stats
        .select(
          "flag_entity_stats.entity_id AS entity_id",
          "entities.name AS entity_name",
          "SUM(flag_entity_stats.total_exposure) AS total_exposure",
          "SUM(flag_entity_stats.contract_count) AS contract_count",
          "MAX(#{severity_score_sql('flag_entity_stats.severity')}) AS max_severity_score"
        )
        .group("flag_entity_stats.entity_id, entities.name")
        .order(Arel.sql("total_exposure DESC, contract_count DESC, entities.name ASC"))

      # When filtering by lead type we must not pre-truncate too early,
      # otherwise lower-exposure but valid leads disappear from the result set.
      query = query.limit(@limit * 4) unless @lead_type.present?

      query
    end

    def detail_rows_by_entity(entity_ids)
      return {} if entity_ids.blank?

      scope = FlagEntityStat.where(entity_id: entity_ids)
      scope = scope.where(severity: @severity) if @severity.present?

      scope
        .select(:entity_id, :flag_type, :severity, :total_exposure, :contract_count)
        .order(total_exposure: :desc)
        .group_by(&:entity_id)
    end

    def build_lead(row, details)
      return nil if details.empty?

      lead_type = classify_lead_type(details.map(&:flag_type))
      return nil if @lead_type.present? && @lead_type != lead_type

      top_flags = details.first(3).map do |stat|
        {
          flag_type: stat.flag_type,
          total_exposure: stat.total_exposure.to_f,
          contract_count: stat.contract_count.to_i,
          severity: stat.severity
        }
      end

      max_score = row.max_severity_score.to_i

      {
        id: "entity-#{row.entity_id}",
        entity_id: row.entity_id,
        entity_name: row.entity_name,
        lead_type: lead_type,
        max_severity: SCORE_TO_SEVERITY.fetch(max_score, "low"),
        confidence: confidence_for(max_score, row.contract_count.to_i),
        total_exposure: row.total_exposure.to_f,
        flagged_contract_count: row.contract_count.to_i,
        top_flags: top_flags
      }
    end

    def classify_lead_type(flag_types)
      prioritized_flag = LEAD_TYPE_PRIORITY.find { |flag_type| flag_types.include?(flag_type) }
      return "multi_flag_risk" if prioritized_flag.nil?

      LEAD_TYPE_BY_FLAG.fetch(prioritized_flag)
    end

    def confidence_for(max_score, contract_count)
      return "low" if contract_count < 2
      return "high" if max_score >= 3
      return "medium" if max_score == 2

      "low"
    end

    def severity_score_sql(column_name)
      <<~SQL.squish
        CASE #{column_name}
          WHEN 'critical' THEN 4
          WHEN 'high' THEN 3
          WHEN 'medium' THEN 2
          WHEN 'low' THEN 1
          ELSE 0
        END
      SQL
    end

    def normalize_severity(value)
      return nil if value.blank?

      normalized = value.to_s
      Flag.severities.key?(normalized) ? normalized : nil
    end

    def normalize_lead_type(value)
      return nil if value.blank?

      normalized = value.to_s
      ALLOWED_LEAD_TYPES.include?(normalized) ? normalized : nil
    end

    def normalize_limit(value)
      parsed = Integer(value, exception: false)
      parsed = DEFAULT_LIMIT if parsed.nil?
      parsed = DEFAULT_LIMIT if parsed <= 0
      [ parsed, MAX_LIMIT ].min
    end

    def lead_type_entity_scope
      return nil if @lead_type.blank? || @lead_type == "multi_flag_risk"

      flag_types = FLAG_TYPES_BY_LEAD_TYPE.fetch(@lead_type, [])
      return nil if flag_types.empty?

      scope = FlagEntityStat.where(flag_type: flag_types)
      scope = scope.where(severity: @severity) if @severity.present?
      scope.select(:entity_id).distinct
    end
  end
end
