# frozen_string_literal: true

require "test_helper"
require "rake"

class GraphTaskTest < ActiveSupport::TestCase
  Rake.application = Rake::Application.new
  Rake.application.define_task(Rake::Task, :environment)
  load Rails.root.join("lib/tasks/graph.rake")

  setup do
    ensure_graph_tasks_loaded
  end

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

  private

  def ensure_graph_tasks_loaded
    return if Rake::Task.task_defined?("graph:refresh_edge_summaries")

    Rake.application.define_task(Rake::Task, :environment) unless Rake::Task.task_defined?(:environment)
    load Rails.root.join("lib/tasks/graph.rake")
  end
end
