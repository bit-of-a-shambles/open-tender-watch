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

  test "perform writes per-severity flags_count cache keys" do
    DashboardStatsJob.new.perform

    [ nil, "high", "medium", "low" ].each do |sev|
      assert_not_nil Rails.cache.read("dashboard/flags_count/sev:#{sev}"),
                     "flags_count for sev:#{sev.inspect} should be cached"
      assert_not_nil Rails.cache.read("dashboard/flags_by_type/sev:#{sev}"),
                     "flags_by_type for sev:#{sev.inspect} should be cached"
    end
  end

  test "perform caches correct contract count" do
    DashboardStatsJob.new.perform

    assert_equal Contract.count, Rails.cache.read("dashboard/contract_count")
  end

  test "perform caches correct flags_count matching live query" do
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

    assert_equal Flag.count, Rails.cache.read("dashboard/flags_count/sev:")
    assert_equal Flag.where(severity: "high").count,
                 Rails.cache.read("dashboard/flags_count/sev:high")
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

  test "perform pre-warms entity-exposure page 1 for both sort orders" do
    Rails.cache.write("dashboard/entity_exposure/gen", 7)

    DashboardStatsJob.new.perform

    %w[value count].each do |sort|
      key = "dashboard/entity_exposure/g7/sort:#{sort}/flag:/sev:/page:1"
      result = Rails.cache.read(key)
      assert_not_nil result, "entity_exposure page 1 sort:#{sort} should be pre-warmed"
      rows, total, pages = result
      assert_kind_of Array, rows
      assert_kind_of Integer, total
      assert_kind_of Integer, pages
    end
  end

  # --- flag_type_severities cache warming ---

  test "perform writes flag_type_severities cache key" do
    DashboardStatsJob.new.perform

    assert_not_nil Rails.cache.read("dashboard/flag_type_severities"),
                   "flag_type_severities should be cached after job runs"
  end

  test "perform caches flag_type_severities as a hash" do
    DashboardStatsJob.new.perform

    cached = Rails.cache.read("dashboard/flag_type_severities")
    assert_kind_of Hash, cached
  end

  test "perform caches flag_type_severities matching the live DB query" do
    entity = entities(:one)
    contract = Contract.create!(
      external_id: "job-sev-test-1", country_code: "PT",
      object: "Severity Cache Test", procedure_type: "Ajuste Direto",
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

    cached = Rails.cache.read("dashboard/flag_type_severities")
    assert_equal "high", cached["A2_PUBLICATION_AFTER_CELEBRATION"],
      "Cached severity for A2 must reflect the DB value 'high', not the static helper's 'low'"
  end
end
