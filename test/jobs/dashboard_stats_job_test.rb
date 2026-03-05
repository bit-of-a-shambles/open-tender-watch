require "test_helper"

class DashboardStatsJobTest < ActiveJob::TestCase
  setup do
    # Test env uses NullStore; swap in a real MemoryStore so we can verify writes.
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "perform writes all expected stable cache keys" do
    DashboardStatsJob.new.perform

    assert_not_nil Rails.cache.read("dashboard/contract_count"),     "contract_count should be cached"
    assert_not_nil Rails.cache.read("dashboard/entity_count"),       "entity_count should be cached"
    assert_not_nil Rails.cache.read("dashboard/source_contract_counts"), "source_contract_counts should be cached"
    assert_not_nil Rails.cache.read("dashboard/entity_type_counts"), "entity_type_counts should be cached"
    assert_not_nil Rails.cache.read("dashboard/flag_types"),         "flag_types should be cached"
    assert_not_nil Rails.cache.read("dashboard/active_sources_count"), "active_sources_count should be cached"
    assert_not_nil Rails.cache.read("dashboard/all_sources"),        "all_sources should be cached"
  end

  test "perform writes default aggregates cache key" do
    DashboardStatsJob.new.perform

    aggregates = Rails.cache.read("dashboard/aggregates/sev:/ft:/sort:value")
    assert_not_nil aggregates, "default aggregates should be cached"
    assert aggregates.key?(:flags_count)
    assert aggregates.key?(:flags_by_type)
    assert aggregates.key?(:flagged_total_exposure)
    assert aggregates.key?(:flagged_contract_count)
    assert aggregates.key?(:flagged_companies_count)
    assert aggregates.key?(:flagged_public_entities_count)
    assert aggregates.key?(:exposure_rows)
    assert_kind_of Array, aggregates[:exposure_rows]
  end

  test "perform caches correct contract count" do
    DashboardStatsJob.new.perform

    assert_equal Contract.count, Rails.cache.read("dashboard/contract_count")
  end

  test "perform caches flagged aggregates matching live queries" do
    # Create a flagged contract so aggregates are non-trivial
    entity = entities(:one)
    contract = Contract.create!(
      external_id: "job-test-agg-1", country_code: "PT",
      object: "Test for job",      procedure_type: "Ajuste Direto",
      base_price: 5000,
      publication_date: Date.new(2025, 1, 10),
      celebration_date: Date.new(2025, 1, 8),
      contracting_entity: entity,
      data_source: data_sources(:portal_base)
    )
    Flag.create!(
      contract: contract, flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high", score: 40, details: {}, fired_at: Time.current
    )

    DashboardStatsJob.new.perform

    aggregates = Rails.cache.read("dashboard/aggregates/sev:/ft:/sort:value")
    assert aggregates[:flags_count] >= 1
    assert aggregates[:flagged_contract_count] >= 1
  end

  test "perform caches all_sources as array of plain hashes" do
    DashboardStatsJob.new.perform

    sources = Rails.cache.read("dashboard/all_sources")
    assert_kind_of Array, sources
    sources.each do |s|
      assert s.key?(:id)
      assert s.key?(:name)
      assert s.key?(:records)
    end
  end
end
