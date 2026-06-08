# frozen_string_literal: true

require "test_helper"

class GraphEdgeSummariesRefreshJobTest < ActiveJob::TestCase
  test "perform refreshes edge summaries and prewarms default graph cache" do
    fake_refresh_service = Minitest::Mock.new
    fake_refresh_service.expect(:call, 42)

    payload = { nodes: [], edges: [], meta: {} }
    fake_network_map_service = Minitest::Mock.new
    fake_network_map_service.expect(:call, payload)

    cache_writes = []
    cache_write_stub = lambda do |key, value, expires_in:|
      cache_writes << { key: key, value: value, expires_in: expires_in }
      true
    end

    Graph::EdgeDailySummaryRefreshService.stub(:new, -> { fake_refresh_service }) do
      Graph::NetworkMapService.stub(:new, ->(**_kwargs) { fake_network_map_service }) do
        Rails.cache.stub(:write, cache_write_stub) do
          job = GraphEdgeSummariesRefreshJob.new
          job.stub(:prewarm_access_levels, %w[public journalist]) do
            job.perform
          end
        end
      end
    end

    fake_refresh_service.verify
    fake_network_map_service.verify

    assert_equal 2, cache_writes.size
    assert_equal [ GraphController::NETWORK_MAP_CACHE_TTL ], cache_writes.map { |w| w[:expires_in] }.uniq
    assert_equal [ payload ], cache_writes.map { |w| w[:value] }.uniq

    expected_prefix = [
      "graph",
      "network-map",
      GraphController::NETWORK_MAP_CACHE_VERSION,
      "none",
      "none",
      Graph::NetworkMapService::DEFAULT_NODE_LIMIT,
      "public-bodies",
      "companies",
      "entities-only",
      "global-network",
      "sources-all",
      "forced-none"
    ].join(":")

    assert_includes cache_writes.map { |w| w[:key] }, "#{expected_prefix}:public"
    assert_includes cache_writes.map { |w| w[:key] }, "#{expected_prefix}:journalist"
  end

  test "prewarm access levels include active token levels and falls back on query errors" do
    job = GraphEdgeSummariesRefreshJob.new

    assert_equal %w[auditor journalist public], job.send(:prewarm_access_levels).sort

    AccessToken.stub(:active, -> { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_equal [ "public" ], job.send(:prewarm_access_levels)
    end
  end

  test "perform logs prewarm failures without aborting refresh" do
    fake_refresh_service = Minitest::Mock.new
    fake_refresh_service.expect(:call, 3)
    logger = Minitest::Mock.new
    logger.expect(:info, nil, [ "GraphEdgeSummariesRefreshJob refreshed 3 edge summary rows" ])
    logger.expect(:warn, nil) { |message| message.include?("cache prewarm failed") }

    Graph::EdgeDailySummaryRefreshService.stub(:new, -> { fake_refresh_service }) do
      Graph::NetworkMapService.stub(:new, ->(**_kwargs) { raise StandardError, "prewarm boom" }) do
        Rails.stub(:logger, logger) do
          GraphEdgeSummariesRefreshJob.new.perform
        end
      end
    end

    assert true
    fake_refresh_service.verify
    logger.verify
  end
end
