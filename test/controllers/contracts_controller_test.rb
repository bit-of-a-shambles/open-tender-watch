require "test_helper"

class ContractsControllerTest < ActionDispatch::IntegrationTest
  def create_contract!(external_id:, object:, data_source: data_sources(:portal_base))
    Contract.create!(
      external_id: external_id,
      country_code: "PT",
      object: object,
      procedure_type: "Ajuste Direto",
      base_price: 1000,
      publication_date: Date.new(2025, 1, 10),
      celebration_date: Date.new(2025, 1, 12),
      contracting_entity: entities(:one),
      data_source: data_source
    )
  end

  test "index renders successfully" do
    get contracts_url
    assert_response :success
  end

  test "index filters by search query" do
    get contracts_url, params: { q: "supply" }
    assert_response :success
  end

  test "index filters by procedure type" do
    get contracts_url, params: { procedure_type: "Ajuste Direto" }
    assert_response :success
  end

  test "index filters by country" do
    get contracts_url, params: { country: "PT" }
    assert_response :success
  end

  test "index paginates with page param" do
    get contracts_url, params: { page: 2 }
    assert_response :success
  end

  test "index filters by selected source ids" do
    portal_contract = create_contract!(
      external_id: "source-filter-1",
      object: "Portal BASE only contract",
      data_source: data_sources(:portal_base)
    )
    sns_contract = create_contract!(
      external_id: "source-filter-2",
      object: "SNS only contract",
      data_source: data_sources(:sns_pt)
    )

    get contracts_url, params: { source_ids: [ data_sources(:sns_pt).id ] }
    assert_response :success
    assert_includes response.body, sns_contract.object
    assert_not_includes response.body, portal_contract.object
  end

  test "index accepts multiple selected source ids" do
    portal_contract = create_contract!(
      external_id: "source-filter-3",
      object: "Portal contract for multi source",
      data_source: data_sources(:portal_base)
    )
    sns_contract = create_contract!(
      external_id: "source-filter-4",
      object: "SNS contract for multi source",
      data_source: data_sources(:sns_pt)
    )
    ted_contract = create_contract!(
      external_id: "source-filter-5",
      object: "TED contract for exclusion",
      data_source: data_sources(:ted_pt)
    )

    get contracts_url, params: { source_ids: [ data_sources(:portal_base).id, data_sources(:sns_pt).id ] }
    assert_response :success
    assert_includes response.body, portal_contract.object
    assert_includes response.body, sns_contract.object
    assert_not_includes response.body, ted_contract.object
  end

  test "index renders source checkbox dropdown controls" do
    get contracts_url
    assert_response :success
    assert_select "details summary", /Sources/
    assert_select "input[type=checkbox][name='source_ids\\[\\]']", minimum: 1
  end

  test "index filters flagged contracts only" do
    flagged = create_contract!(external_id: "flagged-index-1", object: "Flagged Contract Alpha")
    unflagged = create_contract!(external_id: "flagged-index-2", object: "Unflagged Contract Beta")
    Flag.create!(
      contract: flagged,
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      score: 40,
      fired_at: Time.current
    )

    get contracts_url, params: { flagged: "only" }
    assert_response :success
    assert_includes response.body, flagged.object
    assert_not_includes response.body, unflagged.object
  end

  test "index filters unflagged contracts only" do
    flagged = create_contract!(external_id: "flagged-index-3", object: "Flagged Contract Gamma")
    unflagged = create_contract!(external_id: "flagged-index-4", object: "Unflagged Contract Delta")
    Flag.create!(
      contract: flagged,
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      score: 40,
      fired_at: Time.current
    )

    get contracts_url, params: { flagged: "none" }
    assert_response :success
    assert_includes response.body, unflagged.object
    assert_not_includes response.body, flagged.object
  end

  test "index filters by flag_type" do
    contract_a = create_contract!(external_id: "flagged-index-5", object: "Date anomaly contract")
    contract_b = create_contract!(external_id: "flagged-index-6", object: "Other anomaly contract")
    Flag.create!(
      contract: contract_a,
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      score: 40,
      fired_at: Time.current
    )
    Flag.create!(
      contract: contract_b,
      flag_type: "A1_REPEAT_DIRECT_AWARD",
      severity: "medium",
      score: 20,
      fired_at: Time.current
    )

    get contracts_url, params: { flag_type: "A2_PUBLICATION_AFTER_CELEBRATION" }
    assert_response :success
    assert_includes response.body, contract_a.object
    assert_not_includes response.body, contract_b.object
  end

  test "show renders a contract" do
    get contract_url(contracts(:one))
    assert_response :success
  end

  test "show displays flags section when contract has flags" do
    contract = contracts(:one)
    Flag.create!(
      contract: contract,
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      score: 40,
      details: { "publication_date" => "2025-01-10", "celebration_date" => "2025-01-08", "rule" => "A2/A3 date sequence anomaly" },
      fired_at: Time.new(2025, 6, 1, 12, 0, 0)
    )

    get contract_url(contract)
    assert_response :success
    assert_includes response.body, "A2_PUBLICATION_AFTER_CELEBRATION"
    assert_includes response.body, I18n.t("contracts.show.flags.severity_high")
    assert_includes response.body, "A2/A3 date sequence anomaly"
    assert_includes response.body, "2025-06-01"
  end

  test "show displays bidder competition section when bidder data exists" do
    contract = contracts(:one)
    contract.update!(bidder_count: 2)
    bidder = Entity.create!(name: "Bidder Evidence", tax_identifier: "509300300", country_code: "PT", is_company: true)
    ContractBidder.create!(contract: contract, entity: bidder, raw_label: "509300300 - Bidder Evidence")
    ContractBidder.create!(contract: contract, raw_label: "--Unparsed Bidder")

    get contract_url(contract)
    assert_response :success
    assert_includes response.body, I18n.t("contracts.show.competition.heading")
    assert_includes response.body, "Bidder Evidence"
    assert_includes response.body, I18n.t("contracts.show.competition.unparsed_bidder")
  end

  test "index displays bidder count badge when present" do
    contracts(:one).update!(bidder_count: 3)

    get contracts_url
    assert_response :success
    assert_includes response.body, I18n.t("contracts.index.bidder_count", count: 3)
  end

  test "show does not display flags section when contract has no flags" do
    contract = contracts(:two)
    Flag.where(contract: contract).delete_all

    get contract_url(contract)
    assert_response :success
    assert_not_includes response.body, I18n.t("contracts.show.flags.heading")
  end

  test "index filters by date_from (publication_date >=)" do
    contracts(:one).update!(publication_date: Date.new(2025, 6, 1))
    contracts(:two).update!(publication_date: Date.new(2025, 1, 1))

    get contracts_url(date_from: "2025-06-01")
    assert_response :success
    assert_includes response.body, contracts(:one).object
    assert_not_includes response.body, contracts(:two).object
  end

  test "index filters by date_to (publication_date <=)" do
    contracts(:one).update!(publication_date: Date.new(2025, 6, 1))
    contracts(:two).update!(publication_date: Date.new(2025, 1, 1))

    get contracts_url(date_to: "2025-01-31")
    assert_response :success
    assert_not_includes response.body, contracts(:one).object
    assert_includes response.body, contracts(:two).object
  end

  # ---------------------------------------------------------------
  # CSV export
  # ---------------------------------------------------------------

  test "index CSV export returns CSV with correct headers" do
    get contracts_url(format: :csv)
    assert_response :success
    assert_equal "text/csv", response.media_type
    lines = response.body.lines
    assert_equal Contract::CSV_COLUMNS.join(",") + "\n", lines.first
  end

  test "index CSV export includes contract data" do
    get contracts_url(format: :csv)
    assert_response :success
    assert_includes response.body, contracts(:one).external_id
    assert_includes response.body, contracts(:one).object
  end

  test "index CSV export respects filters" do
    contracts(:one).update!(procedure_type: "Concurso Público")
    contracts(:two).update!(procedure_type: "Ajuste Direto")

    get contracts_url(format: :csv, procedure_type: "Concurso Público")
    assert_response :success
    assert_includes response.body, contracts(:one).external_id
    assert_not_includes response.body, contracts(:two).external_id
  end

  test "index CSV export includes flag information" do
    Flag.create!(
      contract: contracts(:one),
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      score: 40,
      fired_at: Time.current
    )

    get contracts_url(format: :csv, flagged: "only")
    assert_response :success
    assert_includes response.body, "A2_PUBLICATION_AFTER_CELEBRATION"
  end

  test "index CSV sets content-disposition with filename" do
    get contracts_url(format: :csv)
    assert_response :success
    assert_match(/open-tender-watch-contracts-.*\.csv/, response.headers["Content-Disposition"])
  end

  test "index JSON export returns JSON array of contracts" do
    get contracts_url(format: :json)
    assert_response :success
    assert_equal "application/json", response.media_type
    data = JSON.parse(response.body)
    assert data.key?("contracts")
    assert data.key?("count")
    assert data.key?("exported_at")
  end

  # ---------------------------------------------------------------
  # JSON export (show)
  # ---------------------------------------------------------------

  test "show JSON export returns full evidence hash" do
    Flag.create!(
      contract: contracts(:one),
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      score: 40,
      details: { "rule" => "A2/A3 date sequence anomaly" },
      fired_at: Time.current
    )

    get contract_url(contracts(:one), format: :json)
    assert_response :success
    assert_equal "application/json", response.media_type
    data = JSON.parse(response.body)
    assert_equal contracts(:one).external_id, data["external_id"]
    assert data.key?("contracting_entity")
    assert data.key?("winners")
    assert data.key?("flags")
    assert_equal 1, data["flags"].size
    assert_equal "A2_PUBLICATION_AFTER_CELEBRATION", data["flags"].first["flag_type"]
    assert data.key?("risk_score")
    assert data.key?("exported_at")
  end

  test "show JSON export works without flags" do
    get contract_url(contracts(:two), format: :json)
    assert_response :success
    data = JSON.parse(response.body)
    assert_equal [], data["flags"]
    assert_equal 0, data["risk_score"]
  end
end
