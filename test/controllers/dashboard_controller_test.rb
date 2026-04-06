require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  def create_public_entity!(name:, tax_identifier:)
    Entity.create!(
      name: name,
      tax_identifier: tax_identifier,
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
  end

  def create_company!(name:, tax_identifier:)
    Entity.create!(
      name: name,
      tax_identifier: tax_identifier,
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
  end

  def create_flagged_contract!(external_id:, object:, flag_type:, base_price: 2500, total_effective_price: nil, contracting_entity: entities(:one), winners: [])
    contract = Contract.create!(
      external_id: external_id,
      country_code: "PT",
      object: object,
      procedure_type: "Ajuste Direto",
      base_price: base_price,
      total_effective_price: total_effective_price || base_price,
      publication_date: Date.new(2025, 1, 10),
      celebration_date: Date.new(2025, 1, 8),
      contracting_entity: contracting_entity,
      data_source: data_sources(:portal_base)
    )

    winners.each do |winner|
      ContractWinner.create!(contract: contract, entity: winner)
    end

    Flag.create!(
      contract: contract,
      flag_type: flag_type,
      severity: "high",
      score: 40,
      details: { "rule" => "A2/A3 date sequence anomaly" },
      fired_at: Time.current
    )
    contract
  end

  test "should get index" do
    get dashboard_index_url
    assert_response :success
  end

  test "dashboard shows real flagged aggregates" do
    contract = create_flagged_contract!(
      external_id: "dashboard-flag-1",
      object: "Contrato com anomalia temporal",
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION"
    )
    Flags::AggregateStatsService.new.call

    get dashboard_index_url
    assert_response :success
    assert_includes response.body, contract.contracting_entity.name
    assert_includes response.body, "Late Publication"
    assert_not_includes response.body, "Auto-direcionamento de emendas"
  end

  test "dashboard shows total exposure and distinct involved entities" do
    public_a = create_public_entity!(name: "Public Body Exposure Alpha", tax_identifier: "599000111")
    public_b = create_public_entity!(name: "Public Body Exposure Beta", tax_identifier: "599000112")
    company_a = create_company!(name: "Company Exposure Alpha", tax_identifier: "599100111")
    company_b = create_company!(name: "Company Exposure Beta", tax_identifier: "599100112")

    create_flagged_contract!(
      external_id: "dashboard-metrics-1",
      object: "Contrato Exposição 1",
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      base_price: 4000,
      contracting_entity: public_a,
      winners: [ company_a ]
    )
    create_flagged_contract!(
      external_id: "dashboard-metrics-2",
      object: "Contrato Exposição 2",
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      base_price: 6000,
      contracting_entity: public_b,
      winners: [ company_b ]
    )
    Flags::AggregateStatsService.new.call

    get dashboard_index_url
    assert_response :success

    assert_includes response.body, "€10,000.00"
    assert_includes response.body, I18n.t("dashboard.exposure.companies", count: 2)
    assert_includes response.body, I18n.t("dashboard.exposure.public_entities", count: 2)
  end

  test "dashboard entity exposure can be sorted by value and count per flag" do
    alpha = create_public_entity!(name: "Sort Entity Alpha", tax_identifier: "599200111")
    beta = create_public_entity!(name: "Sort Entity Beta", tax_identifier: "599200112")

    create_flagged_contract!(
      external_id: "dashboard-sort-1",
      object: "Sort Contract Alpha",
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      base_price: 9000,
      contracting_entity: alpha
    )
    create_flagged_contract!(
      external_id: "dashboard-sort-2",
      object: "Sort Contract Beta 1",
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      base_price: 1900,
      contracting_entity: beta
    )
    create_flagged_contract!(
      external_id: "dashboard-sort-3",
      object: "Sort Contract Beta 2",
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      base_price: 2100,
      contracting_entity: beta
    )
    Flags::AggregateStatsService.new.call

    get dashboard_index_url, params: {
      entity_flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      entity_sort: "value"
    }
    assert_response :success
    assert_operator response.body.index("€9,000.00"), :<, response.body.index("€4,000.00")

    get dashboard_index_url, params: {
      entity_flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      entity_sort: "count"
    }
    assert_response :success
    assert_operator response.body.index("€4,000.00"), :<, response.body.index("€9,000.00")
  end

  test "dashboard shows flag type insight cards with counts" do
    create_flagged_contract!(
      external_id: "insight-card-1",
      object: "Insight Card Contract 1",
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION"
    )
    create_flagged_contract!(
      external_id: "insight-card-2",
      object: "Insight Card Contract 2",
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION"
    )
    create_flagged_contract!(
      external_id: "insight-card-3",
      object: "Insight Card Contract 3",
      flag_type: "A9_PRICE_ANOMALY"
    )

    get dashboard_index_url
    assert_response :success
    assert_includes response.body, "A2_PUBLICATION_AFTER_CELEBRATION"
    assert_includes response.body, "A9_PRICE_ANOMALY"
  end

  test "dashboard severity filter renders all severity buttons" do
    get dashboard_index_url
    assert_response :success
    assert_includes response.body, I18n.t("dashboard.severity_filter.all")
    assert_includes response.body, I18n.t("dashboard.severity_filter.high")
    assert_includes response.body, I18n.t("dashboard.severity_filter.medium")
    assert_includes response.body, I18n.t("dashboard.severity_filter.low")
  end

  test "dashboard severity filter scopes entity exposure by severity" do
    entity = create_public_entity!(name: "Severity Filter Entity", tax_identifier: "599300111")

    high_contract = create_flagged_contract!(
      external_id: "sev-high-1",
      object: "High Severity Contract",
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      base_price: 5000,
      contracting_entity: entity
    )
    medium_contract = Contract.create!(
      external_id: "sev-med-1",
      country_code: "PT",
      object: "Medium Severity Contract",
      procedure_type: "Ajuste Direto",
      base_price: 3000,
      total_effective_price: 3000,
      publication_date: Date.new(2025, 1, 10),
      celebration_date: Date.new(2025, 1, 8),
      contracting_entity: entity,
      data_source: data_sources(:portal_base)
    )
    Flag.create!(
      contract: medium_contract,
      flag_type: "A9_PRICE_ANOMALY",
      severity: "medium",
      score: 30,
      fired_at: Time.current
    )
    Flags::AggregateStatsService.new.call

    get dashboard_index_url, params: { severity: "high" }
    assert_response :success
    assert_includes response.body, "€5,000.00"
    assert_not_includes response.body, "€3,000.00"

    get dashboard_index_url, params: { severity: "medium" }
    assert_response :success
    assert_includes response.body, "€3,000.00"
    assert_not_includes response.body, "€5,000.00"
  end

  test "dashboard sources pane uses real contract counts instead of stale metadata" do
    data_sources(:portal_base).update!(record_count: 0, status: :active)

    get dashboard_index_url
    assert_response :success
    assert_match(/Portal BASE.*2 records/m, response.body)
  end

  # --- Backend/frontend contract tests ---
  #
  # These tests auto-discover all flag action files and assert that the frontend
  # stays in sync: every implemented flag must have pt.yml i18n keys and must
  # appear as an *active* (non-dimmed) card in the methodology pane.
  #
  # Adding a new action file without updating the view/locale will fail here.

  IMPLEMENTED_FLAG_CODES = begin
    action_dir = Rails.root.join("app/services/flags/actions")
    Dir.glob("#{action_dir}/*.rb").flat_map do |path|
      # Match string literals like "A7_ABNORMAL_DIRECT_AWARD_RATE" or "B3_PRICE_HIGH"
      File.read(path).scan(/"([A-Z]\d_[A-Z_]+)"/).flatten.map { |t| t[0, 2] }
    end.uniq.sort
  end

  test "every backend flag action has pt.yml i18n keys for title and desc" do
    assert IMPLEMENTED_FLAG_CODES.any?, "No flag type constants found in action files — check naming"

    IMPLEMENTED_FLAG_CODES.each do |code|
      prefix = code.downcase
      assert I18n.exists?("dashboard.methodology.flags.#{prefix}_title", :pt),
        "pt.yml missing dashboard.methodology.flags.#{prefix}_title (#{code} is implemented)"
      assert I18n.exists?("dashboard.methodology.flags.#{prefix}_desc", :pt),
        "pt.yml missing dashboard.methodology.flags.#{prefix}_desc (#{code} is implemented)"
    end
  end

  test "every backend flag action appears as an active card in the methodology pane" do
    assert IMPLEMENTED_FLAG_CODES.any?, "No flag type constants found in action files — check naming"

    get dashboard_index_url
    assert_response :success
    body = response.body

    IMPLEMENTED_FLAG_CODES.each do |code|
      assert_includes body, ">#{code}<",
        "Methodology pane does not render a card for implemented flag #{code}"

      assert_no_match(
        /<div class="[^"]*opacity-60[^"]*">\s*<span[^>]*>\s*#{Regexp.escape(code)}\s*</,
        body,
        "#{code} is implemented — mark it active in the methodology pane (remove opacity-60)"
      )
    end
  end

  # --- DB-driven severity on insight cards ---

  test "insight card severity badge uses database value not static helper map" do
    # The static FLAG_TYPE_SEVERITY map in ApplicationHelper maps A2 → "low".
    # create_flagged_contract! always creates flags with severity: "high".
    # After the fix, @flag_type_severities is built from the DB, so the badge
    # must show "HIGH" (the DB value), not "LOW" (the stale static map).
    create_flagged_contract!(
      external_id: "db-sev-insight-1",
      object: "DB Driven Severity Contract",
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION"
    )

    get dashboard_index_url
    assert_response :success
    body = response.body

    a2_pos = body.index("A2_PUBLICATION_AFTER_CELEBRATION")
    assert_not_nil a2_pos, "A2 flag type should appear in the response body"

    # Grab a window of HTML around the first occurrence of the flag type token.
    a2_section = body[a2_pos, 1000]
    high_label = I18n.t("dashboard.insights.severity_high", default: "HIGH")
    low_label  = I18n.t("dashboard.insights.severity_low",  default: "LOW")

    assert_includes a2_section, high_label,
      "Expected DB severity label '#{high_label}' near A2 insight card"
    assert_not_includes a2_section, low_label,
      "Static-helper severity label '#{low_label}' must NOT appear near A2 insight card"
  end
end
