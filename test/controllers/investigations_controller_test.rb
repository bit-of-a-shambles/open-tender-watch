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

  test "index requires journalist authentication" do
    get investigations_url

    assert_redirected_to new_access_token_url
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

    post access_token_url, params: { token: access_tokens(:one).token }

    get investigations_url

    assert_response :success
    assert_includes response.body, I18n.t("investigations.title")
    assert_includes response.body, entity.name
    assert_includes response.body, I18n.t("investigations.card.total_exposure")
    assert_includes response.body, I18n.t("investigations.card.open_report")
    assert_includes response.body, investigation_path(entity)
  end

  test "show requires journalist authentication" do
    entity = create_entity!(name: "Restricted Report Entity", tax_identifier: "790000401")

    get investigation_url(entity)

    assert_redirected_to new_access_token_url
  end

  test "show renders report for authenticated users" do
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

    post access_token_url, params: { token: access_tokens(:one).token }

    get investigation_url(authority)

    assert_response :success
    assert_includes response.body, authority.name
    assert_includes response.body, I18n.t("investigations.show.highlights_title")
    assert_includes response.body, I18n.t("investigations.show.metrics_title")
    assert_includes response.body, I18n.t("investigations.show.contracts_title")
    assert_includes response.body, I18n.t("investigations.show.timeline_title")
    assert_includes response.body, I18n.t("investigations.show.flagged_rate_label")
    assert_includes response.body, I18n.t("investigations.show.hhi_label")
    assert_includes response.body, I18n.t("investigations.show.hhi_interpretation", level: I18n.t("investigations.show.hhi_levels.high"))
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

    post access_token_url, params: { token: access_tokens(:one).token }

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

    post access_token_url, params: { token: access_tokens(:one).token }

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

  test "dashboard hides investigations navigation for public users" do
    get dashboard_index_url

    assert_response :success
    refute_includes response.body, investigations_path
  end
end
