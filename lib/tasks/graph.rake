# frozen_string_literal: true

namespace :graph do
  desc "Refresh pre-aggregated daily graph edge summaries"
  task refresh_edge_summaries: :environment do
    refreshed_rows = Graph::EdgeDailySummaryRefreshService.new.call
    puts "Graph edge daily summaries refreshed: #{refreshed_rows}"
  end
end
