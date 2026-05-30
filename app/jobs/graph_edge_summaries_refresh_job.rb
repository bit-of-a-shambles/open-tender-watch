# frozen_string_literal: true

class GraphEdgeSummariesRefreshJob < ApplicationJob
  queue_as :default

  def perform
    row_count = Graph::EdgeDailySummaryRefreshService.new.call
    prewarm_default_network_map_cache
    Rails.logger.info("GraphEdgeSummariesRefreshJob refreshed #{row_count} edge summary rows")
  end

  private

  def prewarm_default_network_map_cache
    payload = Graph::NetworkMapService.new(
      include_public_bodies: true,
      include_companies: true,
      include_individuals: false,
      isolate_network: false,
      node_limit: Graph::NetworkMapService::DEFAULT_NODE_LIMIT
    ).call

    prewarm_access_levels.each do |access_level|
      Rails.cache.write(
        network_map_cache_key(access_level),
        payload,
        expires_in: GraphController::NETWORK_MAP_CACHE_TTL
      )
    end
  rescue StandardError => e
    Rails.logger.warn("GraphEdgeSummariesRefreshJob cache prewarm failed: #{e.class}: #{e.message}")
  end

  def prewarm_access_levels
    ([ "public" ] + AccessToken.active.distinct.pluck(:access_level)).compact_blank.uniq
  rescue StandardError
    [ "public" ]
  end

  def network_map_cache_key(access_level)
    [
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
      "forced-none",
      access_level
    ].join(":")
  end
end
