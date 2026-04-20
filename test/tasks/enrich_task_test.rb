# frozen_string_literal: true

require "test_helper"
require "rake"

class EnrichTaskTest < ActiveSupport::TestCase
  setup do
    Rake.application = Rake::Application.new
    Rake.application.define_task(Rake::Task, :environment)
    load Rails.root.join("lib/tasks/enrich.rake")
    Rake::Task["enrich:company_people"].reenable
    Rake::Task["enrich:company_people_by_risk"].reenable
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

  test "company_people_by_risk processes flagged entities first then remaining" do
    entity = entities(:two) # is_company: true
    enriched_ids = []

    fake_service = Object.new
    fake_service.define_singleton_method(:enrich_entity) do |e|
      enriched_ids << e.id
      true
    end

    PublicContracts::EntityPeopleEnrichmentService.stub(:new, ->(*_args) { fake_service }) do
      ENV["SKIP_ENRICHED"] = "0"
      Rake::Task["enrich:company_people_by_risk"].invoke
      ENV.delete("SKIP_ENRICHED")
    end

    assert_includes enriched_ids, entity.id
  end

  test "company_people_by_risk skips already-enriched entities" do
    entity = entities(:two)
    person = Person.create!(name: "Test Person", country_code: "PT")
    EntityPersonRole.create!(
      entity: entity, person: person, role_type: "manager",
      role_label: "Gerente", source_name: "Registo Comercial", active: true,
      verified_at: Time.current
    )

    enriched_ids = []
    fake_service = Object.new
    fake_service.define_singleton_method(:enrich_entity) do |e|
      enriched_ids << e.id
      false
    end

    PublicContracts::EntityPeopleEnrichmentService.stub(:new, ->(*_args) { fake_service }) do
      Rake::Task["enrich:company_people_by_risk"].invoke
    end

    refute_includes enriched_ids, entity.id
  end

  test "company_people_by_risk handles errors without stopping" do
    fake_service = Object.new
    fake_service.define_singleton_method(:enrich_entity) do |_e|
      raise "network timeout"
    end

    PublicContracts::EntityPeopleEnrichmentService.stub(:new, ->(*_args) { fake_service }) do
      ENV["SKIP_ENRICHED"] = "0"
      assert_nothing_raised do
        Rake::Task["enrich:company_people_by_risk"].invoke
      end
      ENV.delete("SKIP_ENRICHED")
    end
  end

  test "company_people_by_risk respects LIMIT env var" do
    enriched_ids = []
    fake_service = Object.new
    fake_service.define_singleton_method(:enrich_entity) do |e|
      enriched_ids << e.id
      false
    end

    # Create a second company so there are 2 candidates
    extra = Entity.create!(name: "Extra Co", tax_identifier: "509999099", country_code: "PT", is_company: true)

    PublicContracts::EntityPeopleEnrichmentService.stub(:new, ->(*_args) { fake_service }) do
      ENV["SKIP_ENRICHED"] = "0"
      ENV["LIMIT"] = "1"
      Rake::Task["enrich:company_people_by_risk"].reenable
      Rake::Task["enrich:company_people_by_risk"].invoke
      ENV.delete("SKIP_ENRICHED")
      ENV.delete("LIMIT")
    end

    assert_equal 1, enriched_ids.size
  end
end
