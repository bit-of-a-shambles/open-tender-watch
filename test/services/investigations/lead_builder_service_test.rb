# frozen_string_literal: true

require "test_helper"

class Investigations::LeadBuilderServiceTest < ActiveSupport::TestCase
  def create_entity!(name:, tax_identifier:, is_public_body: true, is_company: false)
    Entity.create!(
      name: name,
      tax_identifier: tax_identifier,
      country_code: "PT",
      is_public_body: is_public_body,
      is_company: is_company
    )
  end

  def create_flag_stat!(entity:, flag_type:, severity:, total_exposure:, contract_count: 1)
    FlagEntityStat.create!(
      entity: entity,
      flag_type: flag_type,
      severity: severity,
      total_exposure: total_exposure,
      contract_count: contract_count,
      computed_at: Time.current
    )
  end

  test "returns empty payload when no flag stats exist" do
    result = Investigations::LeadBuilderService.new.call

    assert_equal [], result[:leads]
    assert_equal 0, result.dig(:meta, :candidate_count)
    assert_equal Investigations::LeadBuilderService::DEFAULT_LIMIT, result.dig(:meta, :limit)
  end

  test "ranks leads by total exposure and builds top flag evidence" do
    lower = create_entity!(name: "Lower Exposure Authority", tax_identifier: "780000101")
    higher = create_entity!(name: "Higher Exposure Authority", tax_identifier: "780000102")

    create_flag_stat!(
      entity: lower,
      flag_type: "B2_SUPPLIER_CONCENTRATION",
      severity: "high",
      total_exposure: 2_000,
      contract_count: 3
    )

    create_flag_stat!(
      entity: higher,
      flag_type: "A5_THRESHOLD_SPLITTING",
      severity: "medium",
      total_exposure: 8_000,
      contract_count: 5
    )

    create_flag_stat!(
      entity: higher,
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "medium",
      total_exposure: 1_500,
      contract_count: 2
    )

    result = Investigations::LeadBuilderService.new.call

    assert_equal 2, result[:leads].size

    first_lead = result[:leads].first
    assert_equal higher.id, first_lead[:entity_id]
    assert_equal "threshold_splitting", first_lead[:lead_type]
    assert_equal "medium", first_lead[:max_severity]
    assert_equal "medium", first_lead[:confidence]
    assert_equal 9_500.0, first_lead[:total_exposure]
    assert_equal 7, first_lead[:flagged_contract_count]
    assert_equal [ "A5_THRESHOLD_SPLITTING", "A2_PUBLICATION_AFTER_CELEBRATION" ], first_lead[:top_flags].map { |f| f[:flag_type] }
  end

  test "filters leads by severity" do
    high_entity = create_entity!(name: "High Severity Entity", tax_identifier: "780000201")
    low_entity = create_entity!(name: "Low Severity Entity", tax_identifier: "780000202")

    create_flag_stat!(
      entity: high_entity,
      flag_type: "A1_REPEAT_DIRECT_AWARD",
      severity: "high",
      total_exposure: 4_000,
      contract_count: 4
    )

    create_flag_stat!(
      entity: low_entity,
      flag_type: "C3_MISSING_MANDATORY_FIELDS",
      severity: "low",
      total_exposure: 10_000,
      contract_count: 6
    )

    result = Investigations::LeadBuilderService.new(severity: "high").call

    assert_equal 1, result[:leads].size
    assert_equal high_entity.id, result[:leads].first[:entity_id]
    assert_equal "high", result[:leads].first[:max_severity]
  end

  test "filters leads by lead type" do
    concentration_entity = create_entity!(name: "Concentration Entity", tax_identifier: "780000301")
    split_entity = create_entity!(name: "Split Entity", tax_identifier: "780000302")

    create_flag_stat!(
      entity: concentration_entity,
      flag_type: "B2_SUPPLIER_CONCENTRATION",
      severity: "high",
      total_exposure: 3_000,
      contract_count: 3
    )

    create_flag_stat!(
      entity: split_entity,
      flag_type: "A5_THRESHOLD_SPLITTING",
      severity: "high",
      total_exposure: 7_000,
      contract_count: 5
    )

    result = Investigations::LeadBuilderService.new(lead_type: "supplier_concentration").call

    assert_equal 1, result[:leads].size
    assert_equal concentration_entity.id, result[:leads].first[:entity_id]
    assert_equal "supplier_concentration", result[:leads].first[:lead_type]
  end

  test "normalizes invalid filters and bounds limit" do
    entity = create_entity!(name: "Normalization Entity", tax_identifier: "780000401")
    create_flag_stat!(
      entity: entity,
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "low",
      total_exposure: 1_000,
      contract_count: 1
    )

    result = Investigations::LeadBuilderService.new(
      severity: "not-valid",
      lead_type: "unknown",
      limit: 9999
    ).call

    assert_equal 1, result[:leads].size
    assert_nil result.dig(:meta, :filters, :severity)
    assert_nil result.dig(:meta, :filters, :lead_type)
    assert_equal Investigations::LeadBuilderService::MAX_LIMIT, result.dig(:meta, :limit)
  end

  test "lead_type filter does not drop lower-exposure matching leads" do
    5.times do |index|
      high_entity = create_entity!(name: "High Exposure #{index}", tax_identifier: "780001#{index}01")
      create_flag_stat!(
        entity: high_entity,
        flag_type: "A1_REPEAT_DIRECT_AWARD",
        severity: "high",
        total_exposure: 100_000 - (index * 10_000),
        contract_count: 5
      )
    end

    late_entity = create_entity!(name: "Late Publication Entity", tax_identifier: "780009901")
    create_flag_stat!(
      entity: late_entity,
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "medium",
      total_exposure: 100,
      contract_count: 2
    )

    result = Investigations::LeadBuilderService.new(lead_type: "late_publication", limit: 1).call

    assert_equal 1, result[:leads].size
    assert_equal 1, result.dig(:meta, :candidate_count)
    assert_equal late_entity.id, result[:leads].first[:entity_id]
    assert_equal "late_publication", result[:leads].first[:lead_type]
  end
end
