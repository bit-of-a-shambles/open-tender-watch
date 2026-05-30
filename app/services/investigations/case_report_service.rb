# frozen_string_literal: true

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
      contracts_with_winner_count = contracts_with_winner_count()
      contracts_without_winner_count = [ contracts_total - contracts_with_winner_count, 0 ].max
      winner_company_ids = winner_company_ids()
      people_link_summary = people_link_summary_for(winner_company_ids)

      spend_by_company = spend_by_winner_company
      total_spend = spend_by_company.values.sum
      top_suppliers = top_supplier_rows(spend_by_company, total_spend)

      timeline = timeline_rows
      quarter_end_peak_ratio, year_end_peak_ratio = period_peak_ratios(timeline, contracts_total)

      {
        metrics: {
          contracts_total: contracts_total,
          flagged_contracts_total: flagged_contracts_total,
          flagged_rate: ratio(flagged_contracts_total, contracts_total),
          total_spend: total_spend,
          winner_data_available: contracts_with_winner_count.positive?,
          supplier_spend_available: spend_by_company.any?,
          contracts_with_winner_count: contracts_with_winner_count,
          contracts_without_winner_count: contracts_without_winner_count,
          winner_company_count: winner_company_ids.size,
          top_supplier_count: top_suppliers.size,
          top_supplier_share: ratio(top_suppliers.sum { |row| row[:awarded_value] }, total_spend),
          hhi: hhi(spend_by_company, total_spend),
          linked_individual_count: people_link_summary[:linked_individual_count],
          winner_companies_with_individuals_count: people_link_summary[:winner_companies_with_individuals_count],
          multi_company_individual_count: people_link_summary[:multi_company_individual_count],
          winner_companies_without_people_data_count: people_link_summary[:winner_companies_without_people_data_count],
          winner_company_people_coverage_rate: people_link_summary[:winner_company_people_coverage_rate],
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

    def contracts_with_winner_count
      ContractWinner
        .joins(:contract)
        .where(contracts: { contracting_entity_id: entity.id })
        .distinct
        .count(:contract_id)
    end

    def flagged_contracts_scope
      contracts_scope.joins(:flags).distinct
    end

    def winner_company_ids
      ContractWinner
        .joins(:contract, :entity)
        .where(contracts: { contracting_entity_id: entity.id })
        .where("entities.is_public_body = ? OR entities.is_public_body IS NULL", false)
        .distinct
        .pluck(:entity_id)
    end

    def people_link_summary_for(winner_company_ids)
      company_ids = Array(winner_company_ids).compact.uniq
      return empty_people_link_summary if company_ids.empty?

      role_rows = EntityPersonRole.active
        .where(entity_id: company_ids)
        .where.not(person_id: nil)
        .distinct
        .pluck(:entity_id, :person_id)

      role_company_ids = role_rows.map(&:first).uniq
      role_person_ids = role_rows.map(&:second).uniq

      multi_company_individual_count = EntityPersonRole.active
        .where(entity_id: company_ids)
        .where.not(person_id: nil)
        .group(:person_id)
        .having("COUNT(DISTINCT entity_person_roles.entity_id) > 1")
        .count
        .size

      legacy_company_ids = company_ids - role_company_ids
      legacy_rows = CompanyDirector
        .where(entity_id: legacy_company_ids)
        .distinct
        .pluck(:entity_id, :id)

      legacy_company_ids_with_people = legacy_rows.map(&:first).uniq
      legacy_people_count = legacy_rows.map(&:second).uniq.size

      winner_companies_with_individuals_count = role_company_ids.size + legacy_company_ids_with_people.size

      {
        linked_individual_count: role_person_ids.size + legacy_people_count,
        winner_companies_with_individuals_count: winner_companies_with_individuals_count,
        multi_company_individual_count: multi_company_individual_count,
        winner_companies_without_people_data_count: [ company_ids.size - winner_companies_with_individuals_count, 0 ].max,
        winner_company_people_coverage_rate: ratio(winner_companies_with_individuals_count, company_ids.size)
      }
    end

    def empty_people_link_summary
      {
        linked_individual_count: 0,
        winner_companies_with_individuals_count: 0,
        multi_company_individual_count: 0,
        winner_companies_without_people_data_count: 0,
        winner_company_people_coverage_rate: 0.0
      }
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
      winner_counts_by_contract = ContractWinner
        .joins(:contract)
        .where(contracts: { contracting_entity_id: entity.id })
        .group(:contract_id)
        .count

      return {} if winner_counts_by_contract.empty?

      contract_values = contracts_scope
        .pluck(:id, Arel.sql("COALESCE(total_effective_price, base_price)"))
        .to_h

      return {} if contract_values.empty?

      winner_rows = ContractWinner
        .joins(:contract, :entity)
        .where(contracts: { contracting_entity_id: entity.id })
        .where("entities.is_public_body = ? OR entities.is_public_body IS NULL", false)
        .pluck(:contract_id, :entity_id, :price_share)

      return {} if winner_rows.empty?

      winner_rows.each_with_object(Hash.new(0.0)) do |(contract_id, winner_entity_id, price_share), result|
        allocated_value = if price_share.present?
          price_share.to_f
        else
          winner_count = winner_counts_by_contract[contract_id].to_i
          next if winner_count <= 0

          contract_values[contract_id].to_f / winner_count
        end

        result[winner_entity_id] += allocated_value
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
