# frozen_string_literal: true

require "test_helper"

class PublicOfficials::PT::RoleImportServiceTest < ActiveSupport::TestCase
  test "imports normalized public official role into existing entity" do
    record = {
      person_name: "Ana Paula Matos",
      person_tax_identifier: "222333444",
      public_entity_tax_identifier: entities(:one).tax_identifier,
      public_entity_name: "Câmara Municipal de Lisboa",
      role_type: "director",
      role_label: "Diretora Municipal",
      start_date: "2025-01-10",
      source_url: "https://dre.pt/example",
      source_publication_date: "2025-01-12"
    }

    assert_difference [ "Person.count", "EntityPersonRole.count" ], 1 do
      stats = PublicOfficials::PT::RoleImportService.new(records: [ record ]).call
      assert_equal 1, stats.processed
      assert_equal 1, stats.updated
      assert_equal 0, stats.skipped
    end

    role = EntityPersonRole.find_by!(source_name: "DRE", role_label: "Diretora Municipal")
    assert_equal "Ana Paula Matos", role.name
    assert_equal "222333444", role.tax_identifier
    assert_equal Date.new(2025, 1, 10), role.start_date
    assert_equal Date.new(2025, 1, 12), role.source_publication_date
    assert role.active?
  end

  test "creates synthetic public entity identifier and normalizes unsupported role type" do
    record = {
      "person_name" => "Miguel Sousa",
      "public_entity_name" => "Instituto Público Sem NIPC",
      "role_type" => "vogal",
      "end_date" => "2025-03-01",
      "source_name" => "Entidade Transparência"
    }

    stats = PublicOfficials::PT::RoleImportService.new(records: [ record ]).call
    assert_equal 1, stats.updated

    entity = Entity.find_by!(name: "Instituto Público Sem NIPC")
    assert_match(/\APT-PUBLIC-[0-9a-f]{12}\z/, entity.tax_identifier)
    assert entity.is_public_body?

    role = entity.entity_person_roles.includes(:person).first
    assert_equal "unknown", role.role_type
    assert_equal "Public official", role.role_label
    assert_not role.active?
  end

  test "skips records missing required names and tolerates invalid dates" do
    records = [
      { person_name: "", public_entity_name: "Entidade X" },
      { person_name: "Ana", public_entity_name: "" },
      { person_name: "Data Inválida", public_entity_name: "Entidade Data", start_date: "not-a-date" }
    ]

    stats = PublicOfficials::PT::RoleImportService.new(records: records).call

    assert_equal 3, stats.processed
    assert_equal 1, stats.updated
    assert_equal 2, stats.skipped
    assert_nil EntityPersonRole.find_by!(role_label: "Public official").start_date
  end
end
