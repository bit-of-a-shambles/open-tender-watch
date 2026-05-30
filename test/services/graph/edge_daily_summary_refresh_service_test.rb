# frozen_string_literal: true

require "test_helper"

class Graph::EdgeDailySummaryRefreshServiceTest < ActiveSupport::TestCase
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "call rebuilds summaries and excludes self-loop contracts" do
    source = Entity.create!(
      name: "Summary Source Company",
      tax_identifier: "589100101",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    target = Entity.create!(
      name: "Summary Target Company",
      tax_identifier: "589100102",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    old_row = GraphEdgeDailySummary.create!(
      source_entity: source,
      target_entity: target,
      publication_date: Date.new(2020, 1, 1),
      data_source: data_sources(:portal_base),
      contract_count: 99,
      total_value: 999,
      flagged_contract_count: 99,
      flagged_total_value: 999,
      risk_total_score: 99,
      source_is_public_body: false,
      source_is_company: true,
      target_is_public_body: false,
      target_is_company: true,
      computed_at: Time.current
    )

    flagged_contract = Contract.create!(
      external_id: "graph-summary-flagged",
      country_code: "PT",
      object: "Flagged summary contract",
      contracting_entity: source,
      publication_date: Date.new(2041, 1, 10),
      celebration_date: Date.new(2041, 1, 11),
      data_source: data_sources(:portal_base),
      base_price: 300
    )
    ContractWinner.create!(contract: flagged_contract, entity: target, price_share: 300)
    Flag.create!(
      contract: flagged_contract,
      flag_type: "A1_REPEAT_DIRECT_AWARD",
      severity: "high",
      score: 7,
      fired_at: Time.current
    )

    clean_contract = Contract.create!(
      external_id: "graph-summary-clean",
      country_code: "PT",
      object: "Clean summary contract",
      contracting_entity: source,
      publication_date: Date.new(2041, 1, 10),
      celebration_date: Date.new(2041, 1, 12),
      data_source: data_sources(:portal_base),
      base_price: 120
    )
    ContractWinner.create!(contract: clean_contract, entity: target, price_share: 120)

    self_loop_contract = Contract.create!(
      external_id: "graph-summary-self-loop",
      country_code: "PT",
      object: "Self loop contract",
      contracting_entity: source,
      publication_date: Date.new(2041, 1, 10),
      celebration_date: Date.new(2041, 1, 12),
      data_source: data_sources(:portal_base),
      base_price: 999
    )
    ContractWinner.create!(contract: self_loop_contract, entity: source, price_share: 999)

    Rails.cache.write(Graph::NetworkMapService::PREAGGREGATED_AVAILABILITY_CACHE_KEY, true)

    refreshed_rows = Graph::EdgeDailySummaryRefreshService.new.call

    assert_operator refreshed_rows, :>=, 1
    refute GraphEdgeDailySummary.exists?(old_row.id)
    assert_nil Rails.cache.read(Graph::NetworkMapService::PREAGGREGATED_AVAILABILITY_CACHE_KEY)

    summary = GraphEdgeDailySummary.find_by!(
      source_entity_id: source.id,
      target_entity_id: target.id,
      publication_date: Date.new(2041, 1, 10),
      data_source_id: data_sources(:portal_base).id
    )

    assert_equal 2, summary.contract_count
    assert_equal 420.0, summary.total_value.to_f
    assert_equal 1, summary.flagged_contract_count
    assert_equal 300.0, summary.flagged_total_value.to_f
    assert_equal 7, summary.risk_total_score
    assert_equal true, summary.source_is_company
    assert_equal true, summary.target_is_company
  end

  test "call keeps historical rows outside incremental refresh window" do
    source = Entity.create!(
      name: "Incremental Source Company",
      tax_identifier: "589200101",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    target = Entity.create!(
      name: "Incremental Target Company",
      tax_identifier: "589200102",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    historical_row = GraphEdgeDailySummary.create!(
      source_entity: source,
      target_entity: target,
      publication_date: Date.new(2018, 1, 1),
      data_source: data_sources(:portal_base),
      contract_count: 8,
      total_value: 800,
      flagged_contract_count: 0,
      flagged_total_value: 0,
      risk_total_score: 0,
      source_is_public_body: false,
      source_is_company: true,
      target_is_public_body: false,
      target_is_company: true,
      computed_at: Time.current
    )

    stale_recent_row = GraphEdgeDailySummary.create!(
      source_entity: source,
      target_entity: target,
      publication_date: Date.new(2024, 6, 20),
      data_source: data_sources(:portal_base),
      contract_count: 99,
      total_value: 999,
      flagged_contract_count: 99,
      flagged_total_value: 999,
      risk_total_score: 99,
      source_is_public_body: false,
      source_is_company: true,
      target_is_public_body: false,
      target_is_company: true,
      computed_at: Time.current
    )

    contract = Contract.create!(
      external_id: "graph-summary-incremental-recent",
      country_code: "PT",
      object: "Incremental recent contract",
      contracting_entity: source,
      publication_date: Date.new(2024, 6, 20),
      celebration_date: Date.new(2024, 6, 21),
      data_source: data_sources(:portal_base),
      base_price: 250
    )
    ContractWinner.create!(contract: contract, entity: target, price_share: 250)

    refreshed_rows = Graph::EdgeDailySummaryRefreshService.new.call

    assert_operator refreshed_rows, :>=, 2
    assert GraphEdgeDailySummary.exists?(historical_row.id)
    assert_equal 8, historical_row.reload.contract_count
    refute GraphEdgeDailySummary.exists?(stale_recent_row.id)

    refreshed_recent_row = GraphEdgeDailySummary.find_by!(
      source_entity_id: source.id,
      target_entity_id: target.id,
      publication_date: Date.new(2024, 6, 20),
      data_source_id: data_sources(:portal_base).id
    )

    assert_equal 1, refreshed_recent_row.contract_count
    assert_equal 250.0, refreshed_recent_row.total_value.to_f
    assert_equal 0, refreshed_recent_row.flagged_contract_count
    assert_equal 0.0, refreshed_recent_row.flagged_total_value.to_f
    assert_equal 0, refreshed_recent_row.risk_total_score
  end

  test "call emits refresh telemetry" do
    source = Entity.create!(
      name: "Telemetry Source Company",
      tax_identifier: "589300101",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    target = Entity.create!(
      name: "Telemetry Target Company",
      tax_identifier: "589300102",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    contract = Contract.create!(
      external_id: "graph-summary-telemetry",
      country_code: "PT",
      object: "Telemetry summary contract",
      contracting_entity: source,
      publication_date: Date.new(2044, 2, 10),
      celebration_date: Date.new(2044, 2, 11),
      data_source: data_sources(:portal_base),
      base_price: 180
    )
    ContractWinner.create!(contract: contract, entity: target, price_share: 180)

    events = []
    callback = ->(*args) { events << ActiveSupport::Notifications::Event.new(*args) }

    ActiveSupport::Notifications.subscribed(callback, "graph.edge_summary_refresh") do
      Graph::EdgeDailySummaryRefreshService.new.call
    end

    assert_equal 1, events.size
    payload = events.first.payload
    assert_includes %w[incremental full], payload[:mode]
    assert payload.key?(:refresh_start_date)
    assert_operator payload[:total_rows_before], :>=, 0
    assert_operator payload[:total_rows_after], :>=, 1
    assert_operator payload[:deleted_rows], :>=, 0
    assert_operator payload[:inserted_rows], :>=, 0
    assert_operator payload.dig(:timings_ms, :delete_window), :>=, 0.0
    assert_operator payload.dig(:timings_ms, :insert_window), :>=, 0.0
    assert_operator payload.dig(:timings_ms, :total), :>=, 0.0
  end
end
