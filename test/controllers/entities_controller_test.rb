# frozen_string_literal: true

require "test_helper"

class EntitiesControllerTest < ActionDispatch::IntegrationTest
  test "index renders successfully" do
    get entities_url
    assert_response :success
  end

  test "index filters by search query" do
    get entities_url, params: { q: "Lisboa" }
    assert_response :success
    assert_includes response.body, entities(:one).name
  end

  test "index filters by type public" do
    get entities_url, params: { type: "public" }
    assert_response :success
    assert_includes response.body, entities(:one).name
  end

  test "index filters by type private" do
    get entities_url, params: { type: "private" }
    assert_response :success
    assert_includes response.body, entities(:two).name
  end

  test "index paginates with page param" do
    get entities_url, params: { page: 2 }
    assert_response :success
  end

  test "index short query (1 char) returns all entities unfiltered" do
    get entities_url, params: { q: "L" }
    assert_response :success
  end

  test "show renders entity with contracts" do
    get entity_url(entities(:one))
    assert_response :success
    assert_includes response.body, entities(:one).name
  end

  test "show redirects company entities to company route" do
    get entity_url(entities(:two), format: :html)

    assert_equal "http://www.example.com#{company_path(entities(:two))}?format=html", response.location
  end

  test "show renders network graph panel" do
    get entity_url(entities(:one))
    assert_response :success
    assert_includes response.body, "data-controller=\"entity-network-graph\""
    assert_includes response.body, I18n.t("graph.heading")
  end

  test "show hides anonymized individual toggle for public users" do
    get entity_url(entities(:one))
    assert_response :success
    refute_includes response.body, I18n.t("graph.include_individuals")
  end

  test "show renders anonymized individual toggle for authenticated users" do
    post access_token_url, params: { token: access_tokens(:one).token }

    get entity_url(entities(:one))
    assert_response :success
    assert_includes response.body, I18n.t("graph.include_individuals")
  end

  test "show sorts contracts by base_price" do
    get entity_url(entities(:one), sort: "base_price", dir: "asc")
    assert_response :success
  end

  test "show sorts contracts by object" do
    get entity_url(entities(:one), sort: "object", dir: "asc")
    assert_response :success
  end

  test "show sorts contracts by celebration_date descending" do
    get entity_url(entities(:one), sort: "celebration_date", dir: "desc")
    assert_response :success
  end

  test "show paginates contracts" do
    get entity_url(entities(:one), page: 2)
    assert_response :success
  end

  test "show uses default sort when invalid sort param given" do
    get entity_url(entities(:one), sort: "invalid_col", dir: "sideways")
    assert_response :success
  end

  test "show filters contracts by flag_type" do
    get entity_url(entities(:one), flag_type: "A2")
    assert_response :success
  end

  test "show filters flagged contracts inside the turbo frame without crashing" do
    flag_type = "A2_PUBLICATION_AFTER_CELEBRATION"

    Flag.create!(
      contract: contracts(:one),
      flag_type: flag_type,
      severity: "high",
      score: 40,
      details: { rule: "A2/A3 date sequence anomaly" },
      fired_at: Time.current
    )

    FlagEntityStat.create!(
      entity: entities(:one),
      flag_type: flag_type,
      severity: "high",
      total_exposure: contracts(:one).base_price,
      contract_count: 1,
      computed_at: Time.current
    )

    get entity_url(entities(:one), flag_type: flag_type), headers: { "Turbo-Frame" => "entity-contracts" }

    assert_response :success
    assert_includes response.body, contracts(:one).object
    assert_not_includes response.body, contracts(:two).object
  end

  test "show filters contracts by date_from" do
    contracts(:one).update!(publication_date: Date.new(2025, 6, 1))
    contracts(:two).update!(publication_date: Date.new(2025, 1, 1))

    get entity_url(entities(:one), date_from: "2025-06-01"), headers: { "Turbo-Frame" => "entity-contracts" }
    assert_response :success
    assert_includes response.body, contracts(:one).object
    assert_not_includes response.body, contracts(:two).object
  end

  test "show filters contracts by date_to" do
    contracts(:one).update!(publication_date: Date.new(2025, 6, 1))
    contracts(:two).update!(publication_date: Date.new(2025, 1, 1))

    get entity_url(entities(:one), date_to: "2025-01-31"), headers: { "Turbo-Frame" => "entity-contracts" }
    assert_response :success
    assert_not_includes response.body, contracts(:one).object
    assert_includes response.body, contracts(:two).object
  end

  # ---------------------------------------------------------------
  # CSV export
  # ---------------------------------------------------------------

  test "show CSV export returns CSV with correct headers" do
    get entity_url(entities(:one), format: :csv)
    assert_response :success
    assert_equal "text/csv", response.media_type
    lines = response.body.lines
    assert_equal Contract::CSV_COLUMNS.join(",") + "\n", lines.first
  end

  test "show CSV export includes entity contracts" do
    get entity_url(entities(:one), format: :csv)
    assert_response :success
    assert_includes response.body, contracts(:one).external_id
  end

  test "show CSV export sets filename with entity NIF" do
    get entity_url(entities(:one), format: :csv)
    assert_response :success
    assert_match(/entity-#{entities(:one).tax_identifier}/, response.headers["Content-Disposition"])
  end

  test "show CSV export respects flag filter" do
    Flag.create!(
      contract: contracts(:one),
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      score: 40,
      fired_at: Time.current
    )

    get entity_url(entities(:one), format: :csv, flag_type: "A2_PUBLICATION_AFTER_CELEBRATION")
    assert_response :success
    assert_includes response.body, contracts(:one).external_id
    assert_not_includes response.body, contracts(:two).external_id
  end

  # ---------------------------------------------------------------
  # JSON export
  # ---------------------------------------------------------------

  test "show JSON export returns entity profile" do
    get entity_url(entities(:one), format: :json)
    assert_response :success
    assert_equal "application/json", response.media_type
    data = JSON.parse(response.body)
    assert data.key?("entity")
    assert_equal entities(:one).name, data["entity"]["name"]
    assert_equal entities(:one).tax_identifier, data["entity"]["tax_identifier"]
    assert data.key?("flag_stats")
    assert data.key?("exported_at")
  end

  test "show JSON export includes benford analysis when present" do
    BenfordAnalysis.create!(
      entity: entities(:one),
      sample_size: 100,
      chi_square: 20.5,
      flagged: true,
      digit_distribution: { "1" => 35, "2" => 15, "3" => 10, "4" => 8, "5" => 7, "6" => 6, "7" => 6, "8" => 7, "9" => 6 },
      computed_at: Time.current
    )

    get entity_url(entities(:one), format: :json)
    assert_response :success
    data = JSON.parse(response.body)
    assert data.key?("benford_analysis")
    assert_equal 100, data["benford_analysis"]["sample_size"]
    assert_equal true, data["benford_analysis"]["flagged"]
  end

  test "show JSON export reports canonical severity for flag stats" do
    # Stale DB value ("high") should not leak through — A2 is canonically low.
    FlagEntityStat.create!(
      entity: entities(:one),
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      contract_count: 5,
      total_exposure: 100_000.0,
      computed_at: Time.current
    )

    get entity_url(entities(:one), format: :json)
    assert_response :success
    data = JSON.parse(response.body)
    assert_equal 1, data["flag_stats"].size
    assert_equal "A2_PUBLICATION_AFTER_CELEBRATION", data["flag_stats"].first["flag_type"]
    assert_equal "low", data["flag_stats"].first["severity"]
  end

  test "show collapses A9 sub-flag types into one row per flag_type with severity breakdown" do
    FlagEntityStat.create!(
      entity: entities(:one),
      flag_type: "A9_PRICE_ANOMALY",
      severity: "medium",
      contract_count: 1,
      total_exposure: 25_000,
      computed_at: Time.current
    )

    FlagEntityStat.create!(
      entity: entities(:one),
      flag_type: "A9_PRICE_ANOMALY",
      severity: "high",
      contract_count: 2,
      total_exposure: 60_000,
      computed_at: Time.current
    )

    FlagEntityStat.create!(
      entity: entities(:one),
      flag_type: "A9_PRICE_REDUCTION",
      severity: "low",
      contract_count: 4,
      total_exposure: 10_000,
      computed_at: Time.current
    )

    get entity_url(entities(:one), format: :json)
    assert_response :success

    data = JSON.parse(response.body)
    by_type = data["flag_stats"].group_by { |r| r["flag_type"] }

    anomaly = by_type["A9_PRICE_ANOMALY"].first
    assert_equal 1,      by_type["A9_PRICE_ANOMALY"].size
    assert_equal "high", anomaly["severity"]
    assert_equal 3,      anomaly["contract_count"]
    assert_equal 85_000.0, anomaly["total_exposure"]
    # Breakdown: high listed before medium, with its own count + exposure.
    assert_equal [ "high", "medium" ], anomaly["severity_breakdown"].map { |b| b["severity"] }
    assert_equal [ 2, 1 ],             anomaly["severity_breakdown"].map { |b| b["contract_count"] }
    assert_equal [ 60_000.0, 25_000.0 ], anomaly["severity_breakdown"].map { |b| b["total_exposure"] }

    reduction = by_type["A9_PRICE_REDUCTION"].first
    assert_equal 1,     by_type["A9_PRICE_REDUCTION"].size
    assert_equal "low", reduction["severity"]
    # Single-severity flags still carry a breakdown — with exactly one row.
    assert_equal 1, reduction["severity_breakdown"].size
    assert_equal "low", reduction["severity_breakdown"].first["severity"]
  end

  test "show renders per-severity breakdown inline for flags with mixed severities" do
    FlagEntityStat.create!(
      entity: entities(:one),
      flag_type: "A9_PRICE_ANOMALY",
      severity: "medium",
      contract_count: 1,
      total_exposure: 25_000,
      computed_at: Time.current
    )

    FlagEntityStat.create!(
      entity: entities(:one),
      flag_type: "A9_PRICE_ANOMALY",
      severity: "high",
      contract_count: 2,
      total_exposure: 60_000,
      computed_at: Time.current
    )

    get entity_url(entities(:one))
    assert_response :success
    # Both severity badges appear for A9 — the outer row (high) plus the medium breakdown row.
    assert_includes response.body, I18n.t("dashboard.insights.severity_high")
    assert_includes response.body, I18n.t("dashboard.insights.severity_medium")
  end

  test "show renders low severity badge for late publication regardless of stored severity" do
    FlagEntityStat.create!(
      entity: entities(:one),
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      contract_count: 1,
      total_exposure: contracts(:one).base_price,
      computed_at: Time.current
    )

    get entity_url(entities(:one))
    assert_response :success
    assert_includes response.body, I18n.t("dashboard.insights.severity_low")
  end
end
