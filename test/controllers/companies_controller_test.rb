# frozen_string_literal: true

require "test_helper"

class CompaniesControllerTest < ActionDispatch::IntegrationTest
  test "index renders successfully" do
    get companies_url
    assert_response :success
  end

  test "index shows private entities" do
    get companies_url
    assert_response :success
    assert_includes response.body, entities(:two).name
  end

  test "index does not show public bodies" do
    get companies_url
    # entities(:one) is a public body — must not appear
    assert_not_includes response.body, entities(:one).name
  end

  test "index filters by search query matching name" do
    get companies_url, params: { q: "Ferreira" }
    assert_response :success
    assert_includes response.body, entities(:two).name
  end

  test "index filters by search query matching NIF" do
    get companies_url, params: { q: entities(:two).tax_identifier }
    assert_response :success
    assert_includes response.body, entities(:two).name
  end

  test "index short query (1 char) returns all companies unfiltered" do
    get companies_url, params: { q: "F" }
    assert_response :success
  end

  test "index sorts by won_value" do
    get companies_url, params: { sort: "won_value", dir: "desc" }
    assert_response :success
  end

  test "index sorts by won_count" do
    get companies_url, params: { sort: "won_count", dir: "asc" }
    assert_response :success
  end

  test "index sorts by name" do
    get companies_url, params: { sort: "name", dir: "asc" }
    assert_response :success
  end

  test "index rejects invalid sort column and falls back to won_value" do
    get companies_url, params: { sort: "injected_col", dir: "sideways" }
    assert_response :success
  end

  test "index paginates with page param" do
    get companies_url, params: { page: 2 }
    assert_response :success
  end

  test "show renders company with contracts won" do
    get company_url(entities(:two))
    assert_response :success
    assert_includes response.body, entities(:two).name
  end

  test "show lists contracts won by that company" do
    get company_url(entities(:two))
    assert_response :success
    assert_includes response.body, contracts(:two).object
  end

  test "show sorts contracts by base_price" do
    get company_url(entities(:two), sort: "base_price", dir: "asc")
    assert_response :success
  end

  test "show sorts contracts by object" do
    get company_url(entities(:two), sort: "object", dir: "asc")
    assert_response :success
  end

  test "show sorts contracts by celebration_date descending" do
    get company_url(entities(:two), sort: "celebration_date", dir: "desc")
    assert_response :success
  end

  test "show rejects invalid sort column and falls back to celebration_date" do
    get company_url(entities(:two), sort: "bad_col", dir: "sideways")
    assert_response :success
  end

  test "show paginates contracts" do
    get company_url(entities(:two), page: 2)
    assert_response :success
  end

  test "show filters contracts by flag_type" do
    flag_type = "A2_PUBLICATION_AFTER_CELEBRATION"

    Flag.create!(
      contract: contracts(:two),
      flag_type: flag_type,
      severity: "high",
      score: 40,
      details: { rule: "A2/A3 date sequence anomaly" },
      fired_at: Time.current
    )

    get company_url(entities(:two), flag_type: flag_type),
        headers: { "Turbo-Frame" => "company-contracts" }
    assert_response :success
    assert_includes response.body, contracts(:two).object
  end

  test "show filters contracts by date_from" do
    contracts(:two).update!(publication_date: Date.new(2025, 6, 1))

    get company_url(entities(:two), date_from: "2025-06-01"),
        headers: { "Turbo-Frame" => "company-contracts" }
    assert_response :success
    assert_includes response.body, contracts(:two).object
  end

  test "show filters contracts by date_to" do
    contracts(:two).update!(publication_date: Date.new(2024, 1, 1))

    get company_url(entities(:two), date_to: "2024-12-31"),
        headers: { "Turbo-Frame" => "company-contracts" }
    assert_response :success
    assert_includes response.body, contracts(:two).object
  end

  test "show renders pivot section with contracting authority" do
    get company_url(entities(:two))
    assert_response :success
    # The pivot table header should be present
    assert_includes response.body, I18n.t("companies.show.pivot_heading")
  end

  test "show pivot paginates with pivot_page param" do
    get company_url(entities(:two), pivot_page: 2)
    assert_response :success
  end

  test "show renders directors when present" do
    get company_url(entities(:two))
    assert_response :success
    # heading uses & which is HTML-escaped to &amp; in the response body
    assert_includes response.body, "Directors"
    assert_includes response.body, company_directors(:one).name
    assert_includes response.body, company_directors(:two).name
  end

  test "show renders empty directors state for entity without directors" do
    # entities(:one) is a public body — not normally shown in companies,
    # but we test the directors card logic on a private entity with no directors.
    entity_no_directors = Entity.create!(
      name: "Empresa Sem Diretores",
      tax_identifier: "600000001",
      country_code: "PT",
      is_public_body: false
    )
    get company_url(entity_no_directors)
    assert_response :success
    assert_includes response.body, I18n.t("companies.show.no_directors")
  end
end
