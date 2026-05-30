# frozen_string_literal: true

require "set"

module Investigations
  class CaseReportService
    TOP_CONTRACTS_LIMIT = 30
    TOP_SUPPLIER_COUNT = 3
    QUARTER_END_MONTH_SUFFIXES = %w[-03 -06 -09 -12].freeze
    YEAR_END_MONTH_SUFFIX = "-12"

    def initialize(entity:, top_contract_limit: TOP_CONTRACTS_LIMIT)
      @entity = entity
      parsed_limit = top_contract_limit.to_i
      @top_contract_limit = parsed_limit.positive? ? [ parsed_limit, TOP_CONTRACTS_LIMIT ].min : TOP_CONTRACTS_LIMIT
    end

    def call
      contracts_total = contracts_scope.count
      flagged_contracts_total = flagged_contracts_scope.count(:id)

      spend_by_company = spend_by_winner_company
      total_spend = spend_by_company.values.sum
      top_suppliers = top_supplier_rows(spend_by_company, total_spend)

      linked_individual_count, winner_companies_with_individuals_count = linked_individual_metrics(spend_by_company.keys)

      timeline = timeline_rows
      quarter_end_peak_ratio, year_end_peak_ratio = period_peak_ratios(timeline, contracts_total)

      {
        metrics: {
          contracts_total: contracts_total,
          flagged_contracts_total: flagged_contracts_total,
          flagged_rate: ratio(flagged_contracts_total, contracts_total),
          total_spend: total_spend,
          winner_company_count: spend_by_company.size,
          top_supplier_count: top_suppliers.size,
          top_supplier_share: ratio(top_suppliers.sum { |row| row[:awarded_value] }, total_spend),
          hhi: hhi(spend_by_company, total_spend),
          linked_individual_count: linked_individual_count,
          winner_companies_with_individuals_count: winner_companies_with_individuals_count,
          quarter_end_peak_ratio: quarter_end_peak_ratio,
          year_end_peak_ratio: year_end_peak_ratio
        },
        top_suppliers: top_suppliers,
        top_contracts: top_risk_contract_rows,
        timeline: timeline,
        methodology_note: "Risk scoring combines rule-based indicators with data quality flags. Values and confidence degrade when critical fields are missing."
      }
    end

    private

    attr_reader :entity, :top_contract_limit

    def contracts_scope
      Contract.where(contracting_entity_id: entity.id)
    end

    def flagged_contracts_scope
      contracts_scope.joins(:flags).distinct
    end

    def spend_by_winner_company
      preaggregated = preaggregated_spend_by_winner_company
      return preaggregated if preaggregated.any?

      raw_spend_by_winner_company
    end

    def preaggregated_spend_by_winner_company
      rows = GraphEdgeDailySummary
        .where(source_entity_id: entity.id, target_is_company: true)
        .group(:target_entity_id)
        .pluck(Arel.sql("target_entity_id"), Arel.sql("COALESCE(SUM(total_value), 0)"))

      rows.each_with_object({}) do |(winner_entity_id, awarded_value), result|
        result[winner_entity_id] = awarded_value.to_f
      end
    end

    def raw_spend_by_winner_company
      scoped_contracts_sql = contracts_scope
        .select(:id, :base_price, :total_effective_price)
        .to_sql

      winner_counts_sql = ContractWinner
        .joins("INNER JOIN (#{scoped_contracts_sql}) scoped_contracts ON scoped_contracts.id = contract_winners.contract_id")
        .select("contract_id, COUNT(*) AS winner_count")
        .group(:contract_id)
        .to_sql

      rows = ContractWinner
        .joins("INNER JOIN (#{scoped_contracts_sql}) scoped_contracts ON scoped_contracts.id = contract_winners.contract_id")
        .joins("INNER JOIN entities ON entities.id = contract_winners.entity_id")
        .joins("INNER JOIN (#{winner_counts_sql}) winner_counts ON winner_counts.contract_id = contract_winners.contract_id")
        .where("entities.is_company = ?", true)
        .group("contract_winners.entity_id")
        .pluck(
          Arel.sql("contract_winners.entity_id"),
          Arel.sql("COALESCE(SUM(COALESCE(contract_winners.price_share, COALESCE(scoped_contracts.total_effective_price, scoped_contracts.base_price) / NULLIF(winner_counts.winner_count, 0))), 0)")
        )

      rows.each_with_object({}) do |(winner_entity_id, awarded_value), result|
        result[winner_entity_id] = awarded_value.to_f
      end
    end

    def top_supplier_rows(spend_by_company, total_spend)
      return [] if spend_by_company.empty?

      names = Entity.where(id: spend_by_company.keys).pluck(:id, :name).to_h

      spend_by_company
        .sort_by { |(_, awarded_value)| -awarded_value }
        .first(TOP_SUPPLIER_COUNT)
        .map do |winner_entity_id, awarded_value|
          {
            entity_id: winner_entity_id,
            name: names[winner_entity_id] || "-",
            awarded_value: awarded_value,
            share: ratio(awarded_value, total_spend)
          }
        end
    end

    def linked_individual_metrics(winner_company_ids)
      return [ 0, 0 ] if winner_company_ids.empty?

      role_rows = EntityPersonRole
        .active
        .joins(:person)
        .where(entity_id: winner_company_ids)
        .pluck("entity_person_roles.entity_id", "entity_person_roles.person_id", "people.tax_identifier", "people.name")

      director_rows = CompanyDirector
        .where(entity_id: winner_company_ids)
        .pluck(:entity_id, :tax_identifier, :name)

      individuals = Set.new
      companies_with_individuals = Set.new

      role_rows.each do |entity_id, person_id, tax_identifier, name|
        key = person_key(person_id:, tax_identifier:, name:)
        next if key.blank?

        individuals << key
        companies_with_individuals << entity_id
      end

      director_rows.each do |entity_id, tax_identifier, name|
        key = person_key(tax_identifier:, name:)
        next if key.blank?

        individuals << key
        companies_with_individuals << entity_id
      end

      [ individuals.size, companies_with_individuals.size ]
    end

    def person_key(person_id: nil, tax_identifier: nil, name: nil)
      return "person_id:#{person_id}" if person_id.present?
      return "tax_identifier:#{tax_identifier}" if tax_identifier.present?
      return if name.blank?

      "name:#{name.to_s.strip.downcase.gsub(/\s+/, " ")}"
    end

    def timeline_rows
      month_sql = "strftime('%Y-%m', COALESCE(contracts.celebration_date, contracts.publication_date))"
      scoped_contract_month_sql = "strftime('%Y-%m', COALESCE(scoped_contracts.celebration_date, scoped_contracts.publication_date))"

      adjudication_rows = contracts_scope
        .where("COALESCE(contracts.celebration_date, contracts.publication_date) IS NOT NULL")
        .group(Arel.sql(month_sql))
        .order(Arel.sql("#{month_sql} ASC"))
        .pluck(
          Arel.sql(month_sql),
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(COALESCE(contracts.total_effective_price, contracts.base_price)), 0)")
        )

      timeline = adjudication_rows.each_with_object({}) do |(month, contract_count, total_value), result|
        result[month] = {
          month: month,
          adjudication_count: contract_count.to_i,
          adjudication_value: total_value.to_f,
          amendment_flag_count: 0
        }
      end

      scoped_contracts_sql = contracts_scope
        .where("COALESCE(contracts.celebration_date, contracts.publication_date) IS NOT NULL")
        .select(:id, :celebration_date, :publication_date)
        .to_sql

      amendment_rows = Flag
        .joins("INNER JOIN (#{scoped_contracts_sql}) scoped_contracts ON scoped_contracts.id = flags.contract_id")
        .where("flags.flag_type LIKE ?", "A4_%")
        .group(Arel.sql(scoped_contract_month_sql))
        .pluck(Arel.sql(scoped_contract_month_sql), Arel.sql("COUNT(DISTINCT flags.contract_id)"))

      amendment_rows.each do |month, amendment_count|
        timeline[month] ||= {
          month: month,
          adjudication_count: 0,
          adjudication_value: 0.0,
          amendment_flag_count: 0
        }

        timeline[month][:amendment_flag_count] = amendment_count.to_i
      end

      timeline.values.sort_by { |row| row[:month] }
    end

    def period_peak_ratios(timeline, contracts_total)
      quarter_end_count = timeline.sum do |row|
        month = row[:month].to_s
        QUARTER_END_MONTH_SUFFIXES.any? { |suffix| month.end_with?(suffix) } ? row[:adjudication_count] : 0
      end

      year_end_count = timeline.sum do |row|
        row[:month].to_s.end_with?(YEAR_END_MONTH_SUFFIX) ? row[:adjudication_count] : 0
      end

      [ ratio(quarter_end_count, contracts_total), ratio(year_end_count, contracts_total) ]
    end

    def top_risk_contract_rows
      score_rows = Flag
        .joins(:contract)
        .where(contracts: { contracting_entity_id: entity.id })
        .group("flags.contract_id")
        .order(Arel.sql("SUM(flags.score) DESC, COUNT(flags.id) DESC, MAX(contracts.publication_date) DESC, flags.contract_id DESC"))
        .limit(top_contract_limit)
        .pluck(
          Arel.sql("flags.contract_id"),
          Arel.sql("SUM(flags.score)"),
          Arel.sql("COUNT(flags.id)")
        )

      contract_ids = score_rows.map(&:first)
      contracts_by_id = Contract
        .includes(:winners, :flags)
        .where(id: contract_ids)
        .index_by(&:id)

      score_rows.filter_map do |contract_id, risk_score, flag_count|
        contract = contracts_by_id[contract_id]
        next if contract.nil?

        {
          id: contract.id,
          external_id: contract.external_id,
          object: contract.object,
          publication_date: contract.publication_date,
          celebration_date: contract.celebration_date,
          procedure_type: contract.procedure_type,
          base_price: contract.base_price.to_f,
          total_effective_price: contract.total_effective_price.to_f,
          risk_score: risk_score.to_i,
          flag_count: flag_count.to_i,
          winners: contract.winners.first(3).map(&:name),
          flags: contract.flags
            .sort_by { |flag| [ -flag.score, flag.flag_type ] }
            .map do |flag|
              {
                flag_type: flag.flag_type,
                severity: flag.severity,
                score: flag.score,
                evidence: evidence_excerpt(flag.details)
              }
            end
        }
      end
    end

    def evidence_excerpt(details)
      return "" if details.blank?

      text = if details.is_a?(Hash)
        details.first(2).map { |key, value| "#{key}=#{detail_value(value)}" }.join(" | ")
      else
        details.to_s
      end

      text.to_s.truncate(180)
    end

    def detail_value(value)
      return value.join(",") if value.is_a?(Array)
      return value.to_json if value.is_a?(Hash)

      value
    end

    def hhi(spend_by_company, total_spend)
      return 0.0 if total_spend <= 0.0

      spend_by_company.values.sum do |awarded_value|
        share = awarded_value.to_f / total_spend
        share * share
      end
    end

    def ratio(numerator, denominator)
      return 0.0 if denominator.to_f <= 0.0

      numerator.to_f / denominator.to_f
    end
  end
end
