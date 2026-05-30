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
    assert_in_delta((230_000.0 / 260_000.0), report.dig(:metrics, :top_supplier_share), 0.001)
    assert_in_delta 0.3107, report.dig(:metrics, :hhi), 0.001
    assert_in_delta 0.8, report.dig(:metrics, :quarter_end_peak_ratio), 0.001
    assert_in_delta 0.4, report.dig(:metrics, :year_end_peak_ratio), 0.001
    assert_equal 2, report.dig(:metrics, :linked_individual_count)
    assert_equal 2, report.dig(:metrics, :winner_companies_with_individuals_count)

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
    assert_equal [], report[:top_suppliers]
    assert_equal [], report[:top_contracts]
    assert_equal [], report[:timeline]
  end
end
