# frozen_string_literal: true

require "test_helper"
require "rake"

class EnrichTaskTest < ActiveSupport::TestCase
  setup do
    Rake.application = Rake::Application.new
    Rake.application.define_task(Rake::Task, :environment)
    load Rails.root.join("lib/tasks/enrich.rake")
    Rake::Task["enrich:company_people"].reenable
  end

  test "company_people task prints enrichment stats" do
    captured_kwargs = nil
    fake_service = Object.new
    fake_service.define_singleton_method(:call) do |**kwargs|
      captured_kwargs = kwargs
      { processed: 2, updated: 1, skipped: 1 }
    end

    PublicContracts::EntityPeopleEnrichmentService.stub(:new, ->(*_args) { fake_service }) do
      assert_output("Processed: 2\nUpdated:   1\nSkipped:   1\n") do
        Rake::Task["enrich:company_people"].invoke
      end
    end

    assert_equal({ nif: nil, input: nil, limit: nil, offset: nil }, captured_kwargs)
  end
end