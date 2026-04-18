# frozen_string_literal: true

require "test_helper"

class PublicContracts::EntityPeopleEnrichmentServiceTest < ActiveSupport::TestCase
  test "enrich_entity persists people roles from structured detail" do
    entity = entities(:two)
    scraper = Object.new
    scraper.define_singleton_method(:investigar) do |_nif|
      [
        {
          data: "2024-01-15",
          ligacao: "https://publicacoes.mj.pt/detalhe/1",
          detalhe: {
            people: [
              { name: "Maria Silva", role_type: "manager", role_label: "Gerente", tax_identifier: nil }
            ]
          }
        }
      ]
    end

    service = PublicContracts::EntityPeopleEnrichmentService.new(scraper:, relation: Entity.where(id: entity.id))

    assert_difference [ "Person.count", "EntityPersonRole.count" ], 1 do
      assert service.enrich_entity(entity)
    end

    role = entity.entity_person_roles.active.includes(:person).find_by!(source_name: "Registo Comercial")
    assert_equal "Maria Silva", role.name
    assert_equal "Gerente", role.role
    assert_equal Date.new(2024, 1, 15), role.source_publication_date
  end

  test "enrich_entity deactivates missing active roles from same source" do
    entity = entities(:two)
    old_person = Person.create!(name: "Old Manager", country_code: "PT")
    stale_role = EntityPersonRole.create!(
      entity: entity,
      person: old_person,
      role_type: "manager",
      role_label: "Gerente",
      source_name: "Registo Comercial",
      active: true
    )

    scraper = Object.new
    scraper.define_singleton_method(:investigar) do |_nif|
      [
        {
          data: "2024-02-10",
          ligacao: "https://publicacoes.mj.pt/detalhe/2",
          detalhe: {
            people: [
              { name: "New Manager", role_type: "manager", role_label: "Gerente", tax_identifier: nil }
            ]
          }
        }
      ]
    end

    service = PublicContracts::EntityPeopleEnrichmentService.new(scraper:, relation: Entity.where(id: entity.id))
    assert service.enrich_entity(entity)

    assert_not stale_role.reload.active
    assert entity.entity_person_roles.active.find_by(role_label: "Gerente").name == "New Manager"
  end

  test "enrich_entity falls back to legacy arrays when structured people missing" do
    entity = entities(:two)
    scraper = Object.new
    scraper.define_singleton_method(:investigar) do |_nif|
      [
        {
          data: "2024-03-12",
          ligacao: "https://publicacoes.mj.pt/detalhe/3",
          detalhe: {
            gerentes: [ "Maria Silva" ],
            socios: [ "João Ferreira" ]
          }
        }
      ]
    end

    service = PublicContracts::EntityPeopleEnrichmentService.new(scraper:, relation: Entity.where(id: entity.id))
    assert service.enrich_entity(entity)

    assert_equal [ "João Ferreira", "Maria Silva" ], entity.people.order(:name).pluck(:name)
  end

  test "enrich_entity returns false when no detail has people" do
    entity = entities(:two)
    scraper = Object.new
    scraper.define_singleton_method(:investigar) { |_nif| [ { detalhe: {} } ] }

    service = PublicContracts::EntityPeopleEnrichmentService.new(scraper:, relation: Entity.where(id: entity.id))
    assert_not service.enrich_entity(entity)
  end

  test "call filters relation by nif and counts skipped entities" do
    entity = entities(:two)
    skipped = Entity.create!(name: "Skipped Co", tax_identifier: "600000009", country_code: "PT", is_company: true)
    scraper = Object.new
    scraper.define_singleton_method(:investigar) do |nif|
      nif == entity.tax_identifier ? [ { data: "2024-01-15", ligacao: nil, detalhe: { people: [ { name: "Maria Silva", role_type: "manager", role_label: "Gerente", tax_identifier: nil } ] } } ] : []
    end

    service = PublicContracts::EntityPeopleEnrichmentService.new(scraper:, relation: Entity.where(id: [ entity.id, skipped.id ]))
    stats = service.call(nif: entity.tax_identifier)

    assert_equal({ processed: 1, updated: 1, skipped: 0 }, stats)
  end

  test "call increments skipped count when enrichment returns false" do
    entity = entities(:two)
    scraper = Object.new
    scraper.define_singleton_method(:investigar) { |_nif| [] }

    service = PublicContracts::EntityPeopleEnrichmentService.new(scraper:, relation: Entity.where(id: entity.id))
    stats = service.call

    assert_equal({ processed: 1, updated: 0, skipped: 1 }, stats)
  end

  test "call reads nif list from text input and csv input" do
    entity = entities(:two)
    other = Entity.create!(name: "Outra Co", tax_identifier: "600000010", country_code: "PT", is_company: true)
    scraper = Object.new
    scraper.define_singleton_method(:investigar) do |_nif|
      [ { data: "2024-01-15", ligacao: nil, detalhe: { people: [ { name: "Maria Silva", role_type: "manager", role_label: "Gerente", tax_identifier: nil } ] } } ]
    end

    Dir.mktmpdir do |dir|
      text_path = File.join(dir, "nifs.txt")
      csv_path = File.join(dir, "nifs.csv")
      File.write(text_path, "#{entity.tax_identifier}\n")
      File.write(csv_path, "nif\n#{other.tax_identifier}\n")

      service = PublicContracts::EntityPeopleEnrichmentService.new(scraper:, relation: Entity.where(id: [ entity.id, other.id ]))
      assert_equal 1, service.call(input: text_path)[:processed]
      assert_equal 1, service.call(input: csv_path)[:processed]
    end
  end

  test "parse_date returns nil for invalid date" do
    service = PublicContracts::EntityPeopleEnrichmentService.new(scraper: Object.new)
    assert_nil service.send(:parse_date, "not-a-date")
    assert_nil service.send(:parse_date, nil)
  end

  test "target_relation applies offset and limit and read_input_nifs handles missing path" do
    service = PublicContracts::EntityPeopleEnrichmentService.new(scraper: Object.new, relation: Entity.order(:id))

    relation = service.send(:target_relation, nif: nil, input: nil, limit: 1, offset: 1)
    assert_equal 1, relation.count

    assert_equal [], service.send(:read_input_nifs, "/tmp/definitely-missing-company-people.txt")
    assert_nil service.send(:normalize_nif, "abc")
  end

  test "latest_publication_with_people skips non-hash details and supports tax identifier branch" do
    entity = entities(:two)
    service = PublicContracts::EntityPeopleEnrichmentService.new(scraper: Object.new, relation: Entity.where(id: entity.id))

    publications = [
      { detalhe: "broken" },
      {
        data: "2024-04-01",
        ligacao: "https://publicacoes.mj.pt/detalhe/4",
        detalhe: {
          people: [
            { name: "Pessoa Com NIF", role_type: "administrator", role_label: "Administrador", tax_identifier: "222333444" },
            { name: "", role_type: "manager", role_label: "Gerente", tax_identifier: nil }
          ]
        }
      }
    ]

    detail, = service.send(:latest_publication_with_people, publications)
    assert_equal "Pessoa Com NIF", detail[:people].first[:name]

    assert_difference [ "Person.count", "EntityPersonRole.count" ], 1 do
      service.send(:sync_people, entity, detail[:people], source_url: nil, source_publication_date: Date.new(2024, 4, 1))
    end

    person = Person.find_by!(tax_identifier: "222333444", country_code: "PT")
    assert_equal "Pessoa Com NIF", person.name

    role = entity.entity_person_roles.active.find_by!(person: person)
    assert_equal "Administrador", role.role_label

    assert_equal person.id, service.send(:find_or_initialize_person, entity, { name: "Pessoa Com NIF", tax_identifier: "222333444" }).id
  end

  test "sync_people leaves existing records untouched when unchanged" do
    entity = entities(:two)
    person = Person.create!(name: "Maria Silva", country_code: "PT")
    role = EntityPersonRole.create!(
      entity: entity,
      person: person,
      role_type: "manager",
      role_label: "Gerente",
      source_name: "Registo Comercial",
      active: true,
      verified_at: 1.day.ago
    )

    service = PublicContracts::EntityPeopleEnrichmentService.new(scraper: Object.new, relation: Entity.where(id: entity.id))
    original_updated_at = role.updated_at

    service.send(:sync_people, entity, [ { name: "Maria Silva", role_type: "manager", role_label: "Gerente", tax_identifier: nil } ], source_url: nil, source_publication_date: nil)

    assert_equal original_updated_at.to_i, role.reload.updated_at.to_i
  end
end