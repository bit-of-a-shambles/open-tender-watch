# frozen_string_literal: true

require "test_helper"

class Investigations::CaseReportServiceTest < ActiveSupport::TestCase
  def create_entity!(name:, tax_identifier:, is_public_body: true, is_company: false)
    Entity.create!(
      name: name,
      tax_identifier: tax_identifier,
      country_code: "PT",
      is_public_body: is_public_body,
      is_company: is_company
    )
  end

  def create_contract!(entity:, external_id:, value:, celebration_date:, publication_date: celebration_date)
    Contract.create!(
      external_id: external_id,
      country_code: "PT",
      object: "Contrato #{external_id}",
      contract_type: "Aquisição de Serviços",
      procedure_type: "Ajuste Direto",
      publication_date: publication_date,
      celebration_date: celebration_date,
      base_price: value,
      total_effective_price: value,
      contracting_entity: entity,
      data_source: data_sources(:portal_base)
    )
  end

  def attach_winner!(contract:, winner:, price_share: nil)
    ContractWinner.create!(contract: contract, entity: winner, price_share: price_share)
  end

  def create_flag!(contract:, type:, score:, severity: "high")
    Flag.create!(
      contract: contract,
      flag_type: type,
      severity: severity,
      score: score,
      details: { reason: type.downcase },
      fired_at: Time.current
    )
  end

  test "computes investigation metrics, timeline, and risk contracts" do
    authority = create_entity!(name: "Autoridade de Teste", tax_identifier: "770001001")
    winner_a = create_entity!(name: "Fornecedor A", tax_identifier: "770001101", is_public_body: false, is_company: true)
    winner_b = create_entity!(name: "Fornecedor B", tax_identifier: "770001102", is_public_body: false, is_company: true)
    winner_c = create_entity!(name: "Fornecedor C", tax_identifier: "770001103", is_public_body: false, is_company: true)
    winner_d = create_entity!(name: "Fornecedor D", tax_identifier: "770001104", is_public_body: false, is_company: true)

    c1 = create_contract!(entity: authority, external_id: "case-001", value: 100_000, celebration_date: Date.new(2025, 3, 5))
    c2 = create_contract!(entity: authority, external_id: "case-002", value: 80_000, celebration_date: Date.new(2025, 6, 10))
    c3 = create_contract!(entity: authority, external_id: "case-003", value: 40_000, celebration_date: Date.new(2025, 7, 9))
    c4 = create_contract!(entity: authority, external_id: "case-004", value: 30_000, celebration_date: Date.new(2025, 12, 6))
    c5 = create_contract!(entity: authority, external_id: "case-005", value: 10_000, celebration_date: Date.new(2025, 12, 15))

    attach_winner!(contract: c1, winner: winner_a)
    attach_winner!(contract: c2, winner: winner_b)
    attach_winner!(contract: c3, winner: winner_c)
    attach_winner!(contract: c4, winner: winner_d)
    attach_winner!(contract: c5, winner: winner_a)

    create_flag!(contract: c1, type: "A1_REPEAT_DIRECT_AWARD", score: 12)
    create_flag!(contract: c2, type: "A5_THRESHOLD_SPLITTING", score: 10)
    create_flag!(contract: c3, type: "A2_PUBLICATION_AFTER_CELEBRATION", score: 8)
    create_flag!(contract: c4, type: "A4_AMENDMENT_INFLATION", score: 5)

    EntityPersonRole.create!(
      entity: winner_a,
      person: people(:joao),
      role_type: "director",
      source_name: "fixture",
      active: true
    )

    CompanyDirector.create!(
      entity: winner_b,
      name: "Diretor B",
      role: "Gerente",
      tax_identifier: "770009999",
      country_code: "PT"
    )

    report = Investigations::CaseReportService.new(entity: authority, top_contract_limit: 3).call

    assert_in_delta 0.8, report.dig(:metrics, :flagged_rate), 0.001
    assert_equal true, report.dig(:metrics, :winner_data_available)
    assert_equal true, report.dig(:metrics, :supplier_spend_available)
    assert_equal 5, report.dig(:metrics, :contracts_with_winner_count)
    assert_equal 0, report.dig(:metrics, :contracts_without_winner_count)
    assert_in_delta((230_000.0 / 260_000.0), report.dig(:metrics, :top_supplier_share), 0.001)
    assert_in_delta 0.3107, report.dig(:metrics, :hhi), 0.001
    assert_in_delta 0.8, report.dig(:metrics, :quarter_end_peak_ratio), 0.001
    assert_in_delta 0.4, report.dig(:metrics, :year_end_peak_ratio), 0.001
    assert_equal 2, report.dig(:metrics, :linked_individual_count)
    assert_equal 2, report.dig(:metrics, :winner_companies_with_individuals_count)
    assert_equal 0, report.dig(:metrics, :multi_company_individual_count)
    assert_equal 2, report.dig(:metrics, :winner_companies_without_people_data_count)
    assert_in_delta 0.5, report.dig(:metrics, :winner_company_people_coverage_rate), 0.001

    assert_equal 3, report[:top_contracts].size
    assert_equal c1.id, report[:top_contracts].first[:id]

    december = report[:timeline].find { |row| row[:month] == "2025-12" }
    assert_not_nil december
    assert_equal 1, december[:amendment_flag_count]
  end

  test "returns empty-safe payload when entity has no contracts" do
    entity = create_entity!(name: "Sem Contratos", tax_identifier: "770002001")

    report = Investigations::CaseReportService.new(entity: entity).call

    assert_equal 0, report.dig(:metrics, :contracts_total)
    assert_equal 0, report.dig(:metrics, :flagged_contracts_total)
    assert_equal 0.0, report.dig(:metrics, :flagged_rate)
    assert_equal false, report.dig(:metrics, :winner_data_available)
    assert_equal false, report.dig(:metrics, :supplier_spend_available)
    assert_equal 0, report.dig(:metrics, :contracts_with_winner_count)
    assert_equal 0, report.dig(:metrics, :contracts_without_winner_count)
    assert_equal 0, report.dig(:metrics, :linked_individual_count)
    assert_equal 0, report.dig(:metrics, :winner_companies_with_individuals_count)
    assert_equal 0, report.dig(:metrics, :multi_company_individual_count)
    assert_equal 0, report.dig(:metrics, :winner_companies_without_people_data_count)
    assert_equal 0.0, report.dig(:metrics, :winner_company_people_coverage_rate)
    assert_equal [], report[:top_suppliers]
    assert_equal [], report[:top_contracts]
    assert_equal [], report[:timeline]
  end

  test "marks winner data unavailable when contracts have no winners" do
    authority = create_entity!(name: "Sem Adjudicatarios", tax_identifier: "770002101")

    create_contract!(entity: authority, external_id: "no-winner-1", value: 75_000, celebration_date: Date.new(2025, 1, 15))
    create_contract!(entity: authority, external_id: "no-winner-2", value: 45_000, celebration_date: Date.new(2025, 2, 20))

    report = Investigations::CaseReportService.new(entity: authority).call

    assert_equal 2, report.dig(:metrics, :contracts_total)
    assert_equal false, report.dig(:metrics, :winner_data_available)
    assert_equal false, report.dig(:metrics, :supplier_spend_available)
    assert_equal 0, report.dig(:metrics, :contracts_with_winner_count)
    assert_equal 2, report.dig(:metrics, :contracts_without_winner_count)
    assert_equal 0, report.dig(:metrics, :winner_company_count)
    assert_equal 0.0, report.dig(:metrics, :top_supplier_share)
    assert_equal 0, report.dig(:metrics, :linked_individual_count)
    assert_equal 0, report.dig(:metrics, :winner_companies_with_individuals_count)
    assert_equal 0, report.dig(:metrics, :multi_company_individual_count)
    assert_equal 0, report.dig(:metrics, :winner_companies_without_people_data_count)
    assert_equal 0.0, report.dig(:metrics, :winner_company_people_coverage_rate)
    assert_equal [], report[:top_suppliers]
  end
  test "uses preaggregated spend, explicit price shares, and string evidence excerpts" do
    authority = create_entity!(name: "Preaggregated Authority", tax_identifier: "770003001")
    winner = create_entity!(name: "Preaggregated Winner", tax_identifier: "770003101", is_public_body: false, is_company: true)
    contract = create_contract!(entity: authority, external_id: "case-preagg-1", value: 10_000, celebration_date: Date.new(2025, 5, 1))
    attach_winner!(contract: contract, winner: winner, price_share: 2_500)
    create_flag!(contract: contract, type: "A1_REPEAT_DIRECT_AWARD", score: 12)

    GraphEdgeDailySummary.create!(
      source_entity: authority,
      target_entity: winner,
      publication_date: Date.new(2025, 5, 1),
      data_source: data_sources(:portal_base),
      contract_count: 1,
      total_value: 4_000,
      flagged_contract_count: 1,
      flagged_total_value: 4_000,
      risk_total_score: 12,
      source_is_public_body: true,
      source_is_company: false,
      target_is_public_body: false,
      target_is_company: true,
      computed_at: Time.current
    )

    service = Investigations::CaseReportService.new(entity: authority)
    assert_equal({ winner.id => 4_000.0 }, service.send(:preaggregated_spend_by_winner_company))
    assert_equal({ winner.id => 2_500.0 }, service.send(:raw_spend_by_winner_company))
    assert_equal "raw evidence", service.send(:evidence_excerpt, "raw evidence")
  end

end
