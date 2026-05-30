# frozen_string_literal: true

require "test_helper"

class InvestigationsControllerTest < ActionDispatch::IntegrationTest
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

  def create_contract!(entity:, external_id:, value:, publication_date:, celebration_date: publication_date)
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

  def add_winner!(contract:, winner:, price_share: nil)
    ContractWinner.create!(
      contract: contract,
      entity: winner,
      price_share: price_share
    )
  end

  def add_flag!(contract:, flag_type:, score:, severity: "high")
    Flag.create!(
      contract: contract,
      flag_type: flag_type,
      severity: severity,
      score: score,
      details: { reason: flag_type.downcase },
      fired_at: Time.current
    )
  end

  test "index is publicly accessible" do
    get investigations_url

    assert_response :success
  end

  test "index renders automated leads for authenticated users" do
    entity = create_entity!(name: "Investigation Entity", tax_identifier: "790000101")
    create_flag_stat!(
      entity: entity,
      flag_type: "A1_REPEAT_DIRECT_AWARD",
      severity: "high",
      total_exposure: 9_500,
      contract_count: 6
    )

    get investigations_url

    assert_response :success
    assert_includes response.body, I18n.t("investigations.title")
    assert_includes response.body, entity.name
    assert_includes response.body, I18n.t("investigations.card.total_exposure")
    assert_includes response.body, I18n.t("investigations.card.open_report")
    assert_includes response.body, investigation_path(entity)
    assert_includes response.body, I18n.t("investigations.summary.top_per_type", count: 20)
  end

  test "index groups leads by lead type when no type filter is provided" do
    repeat_entity = create_entity!(name: "Repeat Lead Entity", tax_identifier: "790000111")
    late_entity = create_entity!(name: "Late Lead Entity", tax_identifier: "790000112")

    create_flag_stat!(
      entity: repeat_entity,
      flag_type: "A1_REPEAT_DIRECT_AWARD",
      severity: "high",
      total_exposure: 12_000,
      contract_count: 4
    )

    create_flag_stat!(
      entity: late_entity,
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "medium",
      total_exposure: 5_500,
      contract_count: 3
    )

    post access_token_url, params: { token: access_tokens(:one).token }

    get investigations_url

    assert_response :success
    assert_includes response.body, I18n.t("investigations.lead_types.repeat_direct_awards")
    assert_includes response.body, I18n.t("investigations.lead_types.late_publication")
    assert_includes response.body, repeat_entity.name
    assert_includes response.body, late_entity.name
  end

  test "index caps each lead type at top 20 when no type filter is provided" do
    21.times do |index|
      entity = create_entity!(
        name: "Repeat Lead #{index}",
        tax_identifier: format("%09d", 790001000 + index)
      )

      create_flag_stat!(
        entity: entity,
        flag_type: "A1_REPEAT_DIRECT_AWARD",
        severity: "high",
        total_exposure: 50_000 - index,
        contract_count: 2
      )
    end

    post access_token_url, params: { token: access_tokens(:one).token }

    get investigations_url

    assert_response :success
    assert_includes response.body, "Repeat Lead 0"
    refute_includes response.body, "Repeat Lead 20"
  end

  test "show is publicly accessible" do
    entity = create_entity!(name: "Restricted Report Entity", tax_identifier: "790000401")

    get investigation_url(entity)

    assert_response :success
  end

  test "show renders report for public users" do
    authority = create_entity!(name: "Hospital Público Alfa", tax_identifier: "790000402")
    supplier = create_entity!(
      name: "Fornecedor Alfa",
      tax_identifier: "790000403",
      is_public_body: false,
      is_company: true
    )

    contract = create_contract!(
      entity: authority,
      external_id: "report-001",
      value: 120_000,
      publication_date: Date.new(2025, 12, 10),
      celebration_date: Date.new(2025, 12, 5)
    )
    add_winner!(contract: contract, winner: supplier)
    add_flag!(contract: contract, flag_type: "A1_REPEAT_DIRECT_AWARD", score: 12)

    EntityPersonRole.create!(
      entity: supplier,
      person: people(:joao),
      role_type: "director",
      source_name: "fixture",
      active: true
    )

    get investigation_url(authority)

    assert_response :success
    assert_includes response.body, authority.name
    assert_includes response.body, I18n.t("investigations.show.highlights_title")
    assert_includes response.body, I18n.t("investigations.show.metrics_title")
    assert_includes response.body, I18n.t("investigations.show.contracts_title")
    assert_includes response.body, I18n.t("investigations.show.timeline_title")
    assert_includes response.body, I18n.t("investigations.show.flagged_rate_label")
    assert_includes response.body, I18n.t("investigations.show.hhi_label")
    assert_includes response.body, I18n.t(
      "investigations.show.highlight_flagged_contracts",
      flagged: "1",
      total: "1",
      rate: "100%"
    )
    assert_includes response.body, I18n.t(
      "investigations.show.highlight_supplier_concentration_level",
      level: I18n.t("investigations.show.hhi_levels.high"),
      hhi: "1.0000"
    )
    assert_includes response.body, I18n.t(
      "investigations.show.highlight_individual_links",
      people: "1",
      companies: "1"
    )
    assert_includes response.body, I18n.t("investigations.show.hhi_interpretation", level: I18n.t("investigations.show.hhi_levels.high"))
    refute_includes response.body, people(:joao).name
    refute_includes response.body, people(:joao).tax_identifier
  end

  test "show highlights aggregate people-link coverage when winner people data is partial" do
    authority = create_entity!(name: "Cobertura Parcial", tax_identifier: "790000406")
    supplier_with_people = create_entity!(
      name: "Fornecedor Ligado",
      tax_identifier: "790000407",
      is_public_body: false,
      is_company: true
    )
    supplier_without_people = create_entity!(
      name: "Fornecedor Sem Ligacao",
      tax_identifier: "790000408",
      is_public_body: false,
      is_company: true
    )

    first_contract = create_contract!(
      entity: authority,
      external_id: "report-coverage-001",
      value: 90_000,
      publication_date: Date.new(2025, 3, 14),
      celebration_date: Date.new(2025, 3, 14)
    )
    second_contract = create_contract!(
      entity: authority,
      external_id: "report-coverage-002",
      value: 70_000,
      publication_date: Date.new(2025, 4, 11),
      celebration_date: Date.new(2025, 4, 10)
    )

    add_winner!(contract: first_contract, winner: supplier_with_people)
    add_winner!(contract: second_contract, winner: supplier_without_people)
    add_flag!(contract: first_contract, flag_type: "A1_REPEAT_DIRECT_AWARD", score: 8)

    EntityPersonRole.create!(
      entity: supplier_with_people,
      person: people(:joao),
      role_type: "director",
      source_name: "fixture",
      active: true
    )

    get investigation_url(authority)

    assert_response :success
    assert_includes response.body, I18n.t(
      "investigations.show.highlight_people_links_coverage",
      with_people: "1",
      without_people: "1",
      total: "2",
      coverage: "50%"
    )
    refute_includes response.body, people(:joao).name
    refute_includes response.body, people(:joao).tax_identifier
  end

  test "show highlights missing winner data and neutral period distribution" do
    authority = create_entity!(name: "Sem Adjudicatarios Show", tax_identifier: "790000404")

    12.times do |index|
      month = index + 1
      create_contract!(
        entity: authority,
        external_id: "no-winner-show-#{month}",
        value: 10_000 + index,
        publication_date: Date.new(2025, month, 10),
        celebration_date: Date.new(2025, month, 10)
      )
    end

    get investigation_url(authority)

    assert_response :success
    assert_includes response.body, I18n.t(
      "investigations.show.highlight_missing_winner_data",
      with_winner: "0",
      without_winner: "12",
      total: "12"
    )

    neutral_label = I18n.t(
      "investigations.show.highlight_period_distribution",
      quarter: "Q",
      year_end: "Y"
    ).split(":").first

    assert_includes response.body, neutral_label
  end

  test "index applies lead type filter" do
    concentration = create_entity!(name: "Concentration Lead", tax_identifier: "790000201")
    splitting = create_entity!(name: "Threshold Lead", tax_identifier: "790000202")

    create_flag_stat!(
      entity: concentration,
      flag_type: "B2_SUPPLIER_CONCENTRATION",
      severity: "high",
      total_exposure: 8_000,
      contract_count: 5
    )

    create_flag_stat!(
      entity: splitting,
      flag_type: "A5_THRESHOLD_SPLITTING",
      severity: "high",
      total_exposure: 7_000,
      contract_count: 5
    )

    get investigations_url, params: { lead_type: "supplier_concentration" }

    assert_response :success
    assert_includes response.body, concentration.name
    refute_includes response.body, splitting.name
  end

  test "index ignores invalid filters" do
    entity = create_entity!(name: "Invalid Filter Entity", tax_identifier: "790000301")
    create_flag_stat!(
      entity: entity,
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "medium",
      total_exposure: 5_000,
      contract_count: 3
    )

    get investigations_url, params: { severity: "bad", lead_type: "bad" }

    assert_response :success
    assert_includes response.body, entity.name
  end

  test "dashboard shows investigations navigation for authenticated users" do
    post access_token_url, params: { token: access_tokens(:one).token }

    get dashboard_index_url

    assert_response :success
    assert_includes response.body, investigations_path
    assert_includes response.body, I18n.t("nav.investigations")
  end

  test "dashboard shows investigations navigation for public users" do
    get dashboard_index_url

    assert_response :success
    assert_includes response.body, investigations_path
  end
end
