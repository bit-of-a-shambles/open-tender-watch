# frozen_string_literal: true

require "test_helper"
require "rake"

class GraphTaskTest < ActiveSupport::TestCase
  Rake.application = Rake::Application.new
  Rake.application.define_task(Rake::Task, :environment)
  load Rails.root.join("lib/tasks/graph.rake")

  test "refresh_edge_summaries task invokes refresh service" do
    fake_service = Minitest::Mock.new
    fake_service.expect(:call, 17)

    Graph::EdgeDailySummaryRefreshService.stub(:new, -> { fake_service }) do
      Rake::Task["graph:refresh_edge_summaries"].reenable
      assert_output(/Graph edge daily summaries refreshed: 17/) do
        Rake::Task["graph:refresh_edge_summaries"].invoke
      end
    end

    fake_service.verify
  end
end
