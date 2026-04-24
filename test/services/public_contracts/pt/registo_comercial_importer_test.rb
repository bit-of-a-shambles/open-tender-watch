# frozen_string_literal: true

require "test_helper"

class PublicContracts::PT::RegistoComercialImporterTest < ActiveSupport::TestCase
  setup do
    @importer = PublicContracts::PT::RegistoComercialImporter.new
    @entity = entities(:two) # Construções Ferreira Lda, NIF 509999001, is_company: true
  end

  # ── import_nif ─────────────────────────────────────────────────

  test "import_nif skips NIF with error" do
    stats = @importer.import_nif("509999001", { "error" => "search_failed" })
    assert_equal 1, stats.processed
    assert_equal 1, stats.skipped
    assert_equal 0, stats.updated
  end

  test "import_nif skips NIF with zero results" do
    stats = @importer.import_nif("509999001", { "totalResults" => 0, "rows" => [], "publications" => [] })
    assert_equal 1, stats.processed
    assert_equal 1, stats.skipped
  end

  test "import_nif skips NIF not found in database" do
    stats = @importer.import_nif("000000000", { "totalResults" => 1, "publications" => [
      { "date" => "2024-01-15", "text" => "GERÊNCIA:\nNome/Firma: João Silva\nCargo: Gerente" }
    ] })
    assert_equal 1, stats.processed
    assert_equal 1, stats.skipped
  end

  test "import_nif creates person and role from gerência publication" do
    nif_data = {
      "totalResults" => 1,
      "publications" => [
        {
          "date" => "2024-01-15",
          "text" => "GERÊNCIA:\nNome/Firma: Carlos Ferreira\nNIF/NIPC: 111222333\nCargo: Gerente\nOs documentos foram apresentados.",
          "hasPeople" => true
        }
      ]
    }

    assert_difference -> { Person.count }, 1 do
      assert_difference -> { EntityPersonRole.count }, 1 do
        stats = @importer.import_nif(@entity.tax_identifier, nif_data)
        assert_equal 1, stats.updated
        assert_equal 1, stats.roles_created
      end
    end

    person = Person.find_by(tax_identifier: "111222333", country_code: "PT")
    assert_equal "Carlos Ferreira", person.name

    role = @entity.entity_person_roles.find_by(person: person)
    assert_equal "manager", role.role_type
    assert_equal "Gerente", role.role_label
    assert_equal "Registo Comercial", role.source_name
    assert role.active
    assert_equal Date.parse("2024-01-15"), role.start_date
    assert_nil role.end_date
  end

  test "import_nif handles cessation creating inactive role" do
    nif_data = {
      "totalResults" => 2,
      "publications" => [
        {
          "date" => "2024-06-01",
          "text" => "GERÊNCIA:\nNome/Firma: Ana Costa\nNIF/NIPC: 444555666\nCausa: renúncia\nOs documentos foram apresentados.",
          "hasPeople" => true
        },
        {
          "date" => "2023-01-01",
          "text" => "GERÊNCIA:\nNome/Firma: Ana Costa\nNIF/NIPC: 444555666\nCargo: Gerente\nOs documentos foram apresentados.",
          "hasPeople" => true
        }
      ]
    }

    stats = @importer.import_nif(@entity.tax_identifier, nif_data)
    assert_equal 1, stats.updated

    person = Person.find_by(tax_identifier: "444555666", country_code: "PT")
    role = @entity.entity_person_roles.find_by(person: person)
    assert_equal "manager", role.role_type
    refute role.active
    assert_equal Date.parse("2023-01-01"), role.start_date
    assert_equal Date.parse("2024-06-01"), role.end_date
  end

  test "import_nif parses sócios e quotas" do
    nif_data = {
      "totalResults" => 1,
      "publications" => [
        {
          "date" => "2024-03-10",
          "text" => "SÓCIOS E QUOTAS:\nQUOTA :\nTITULAR: Manuel Rodrigues\nNIF/NIPC: 777888999\nValor: 10000\nOs documentos foram apresentados.",
          "hasPeople" => true
        }
      ]
    }

    stats = @importer.import_nif(@entity.tax_identifier, nif_data)
    assert_equal 1, stats.updated

    person = Person.find_by(tax_identifier: "777888999", country_code: "PT")
    assert_equal "Manuel Rodrigues", person.name

    role = @entity.entity_person_roles.find_by(person: person)
    assert_equal "partner_shareholder", role.role_type
    assert_equal "Sócio", role.role_label
  end

  test "import_nif parses administração" do
    nif_data = {
      "totalResults" => 1,
      "publications" => [
        {
          "date" => "2024-02-20",
          "text" => "CONSELHO DE ADMINISTRAÇÃO:\nNome/Firma: Pedro Santos\nNIF/NIPC: 333444555\nCargo: Presidente\nOs documentos foram apresentados.",
          "hasPeople" => true
        }
      ]
    }

    stats = @importer.import_nif(@entity.tax_identifier, nif_data)
    assert_equal 1, stats.updated

    role = @entity.entity_person_roles.joins(:person).find_by(person: { tax_identifier: "333444555" })
    assert_equal "manager", role.role_type
    assert_equal "Presidente", role.role_label
  end

  test "import_nif deactivates old roles no longer in stints" do
    # Pre-create a role that won't appear in the new publications
    person = Person.create!(name: "Old Manager", tax_identifier: "999111222", country_code: "PT")
    old_role = EntityPersonRole.create!(
      entity: @entity, person: person, role_type: "manager",
      role_label: "Gerente", source_name: "Registo Comercial", active: true,
      verified_at: 1.year.ago, start_date: Date.parse("2020-01-01")
    )

    nif_data = {
      "totalResults" => 1,
      "publications" => [
        {
          "date" => "2024-01-15",
          "text" => "GERÊNCIA:\nNome/Firma: New Manager\nNIF/NIPC: 888777666\nCargo: Gerente\nOs documentos foram apresentados.",
          "hasPeople" => true
        }
      ]
    }

    @importer.import_nif(@entity.tax_identifier, nif_data)

    old_role.reload
    refute old_role.active
  end

  test "import_nif is idempotent" do
    nif_data = {
      "totalResults" => 1,
      "publications" => [
        {
          "date" => "2024-01-15",
          "text" => "GERÊNCIA:\nNome/Firma: Carlos Ferreira\nNIF/NIPC: 111222333\nCargo: Gerente\nOs documentos foram apresentados.",
          "hasPeople" => true
        }
      ]
    }

    @importer.import_nif(@entity.tax_identifier, nif_data)
    initial_count = EntityPersonRole.count

    @importer.import_nif(@entity.tax_identifier, nif_data)
    assert_equal initial_count, EntityPersonRole.count
  end

  # ── import_file ────────────────────────────────────────────────

  test "import_file processes all NIFs in JSON" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "results.json")
      data = {
        @entity.tax_identifier => {
          "totalResults" => 1,
          "publications" => [
            {
              "date" => "2024-01-15",
              "text" => "GERÊNCIA:\nNome/Firma: File Test Person\nNIF/NIPC: 222333444\nCargo: Gerente\nOs documentos foram apresentados.",
              "hasPeople" => true
            }
          ]
        },
        "000000000" => { "error" => "search_failed" }
      }
      File.write(path, JSON.generate(data))

      stats = @importer.import_file(path)
      assert_equal 2, stats.processed
      assert_equal 1, stats.updated
      assert_equal 1, stats.skipped
    end
  end

  test "import_file handles empty JSON" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "empty.json")
      File.write(path, "{}")

      stats = @importer.import_file(path)
      assert_equal 0, stats.processed
    end
  end

  # ── edge cases ──────────────────────────────────────────────

  test "import_nif skips when publications yield no stints" do
    nif_data = {
      "totalResults" => 1,
      "publications" => [
        { "date" => "2024-01-15", "text" => "Nenhuma informação relevante.", "hasPeople" => false }
      ]
    }

    stats = @importer.import_nif(@entity.tax_identifier, nif_data)
    assert_equal 1, stats.skipped
  end

  test "import_nif parses fiscal único" do
    nif_data = {
      "totalResults" => 1,
      "publications" => [
        {
          "date" => "2024-05-20",
          "text" => "FISCAL ÚNICO:\nNome/Firma: Rui Barbosa\nNIF/NIPC: 555666777\nCargo: Fiscal Único\nOs documentos foram apresentados.",
          "hasPeople" => true
        }
      ]
    }

    stats = @importer.import_nif(@entity.tax_identifier, nif_data)
    assert_equal 1, stats.updated

    role = @entity.entity_person_roles.joins(:person).find_by(person: { tax_identifier: "555666777" })
    assert_equal "officer", role.role_type
    assert_equal "Fiscal Único", role.role_label
  end

  test "import_nif handles administração cessation" do
    nif_data = {
      "totalResults" => 2,
      "publications" => [
        {
          "date" => "2024-08-01",
          "text" => "CONSELHO DE ADMINISTRAÇÃO:\nNome/Firma: Sofia Leal\nNIF/NIPC: 666777888\nCargo: Presidente\nCausa: renúncia\nOs documentos foram apresentados.",
          "hasPeople" => true
        },
        {
          "date" => "2023-03-01",
          "text" => "CONSELHO DE ADMINISTRAÇÃO:\nNome/Firma: Sofia Leal\nNIF/NIPC: 666777888\nCargo: Presidente\nOs documentos foram apresentados.",
          "hasPeople" => true
        }
      ]
    }

    stats = @importer.import_nif(@entity.tax_identifier, nif_data)
    assert_equal 1, stats.updated

    role = @entity.entity_person_roles.joins(:person).find_by(person: { tax_identifier: "666777888" })
    refute role.active
    assert_equal Date.parse("2024-08-01"), role.end_date
  end

  test "import_nif handles fiscal único cessation" do
    nif_data = {
      "totalResults" => 2,
      "publications" => [
        {
          "date" => "2024-09-01",
          "text" => "FISCAL ÚNICO:\nNome/Firma: Tiago Mendes\nNIF/NIPC: 111333555\nCausa: caducidade\nOs documentos foram apresentados.",
          "hasPeople" => true
        },
        {
          "date" => "2022-01-01",
          "text" => "FISCAL ÚNICO:\nNome/Firma: Tiago Mendes\nNIF/NIPC: 111333555\nCargo: Fiscal Único\nOs documentos foram apresentados.",
          "hasPeople" => true
        }
      ]
    }

    stats = @importer.import_nif(@entity.tax_identifier, nif_data)
    assert_equal 1, stats.updated

    role = @entity.entity_person_roles.joins(:person).find_by(person: { tax_identifier: "111333555" })
    assert_equal "officer", role.role_type
    refute role.active
    assert_equal Date.parse("2024-09-01"), role.end_date
  end

  test "import_nif handles cessation without prior designation" do
    nif_data = {
      "totalResults" => 1,
      "publications" => [
        {
          "date" => "2024-07-01",
          "text" => "GERÊNCIA:\nNome/Firma: Orphan Manager\nNIF/NIPC: 999000111\nCausa: destituição\nOs documentos foram apresentados.",
          "hasPeople" => true
        }
      ]
    }

    stats = @importer.import_nif(@entity.tax_identifier, nif_data)
    assert_equal 1, stats.updated

    role = @entity.entity_person_roles.joins(:person).find_by(person: { tax_identifier: "999000111" })
    assert_equal "manager", role.role_type
    refute role.active
    assert_nil role.start_date
    assert_equal Date.parse("2024-07-01"), role.end_date
  end

  test "import_nif finds person by name when no tax_identifier" do
    person = Person.create!(name: "Existing Person", country_code: "PT")
    EntityPersonRole.create!(
      entity: @entity, person: person, role_type: "manager",
      role_label: "Gerente", source_name: "Other Source", active: true,
      verified_at: 1.year.ago
    )

    nif_data = {
      "totalResults" => 1,
      "publications" => [
        {
          "date" => "2024-01-15",
          "text" => "GERÊNCIA:\nNome/Firma: Existing Person\nCargo: Gerente\nOs documentos foram apresentados.",
          "hasPeople" => true
        }
      ]
    }

    assert_no_difference -> { Person.count } do
      @importer.import_nif(@entity.tax_identifier, nif_data)
    end

    role = @entity.entity_person_roles.find_by(person: person, source_name: "Registo Comercial")
    assert role
    assert_equal "manager", role.role_type
  end

  test "import_nif handles invalid dates gracefully" do
    nif_data = {
      "totalResults" => 1,
      "publications" => [
        {
          "date" => "not-a-date",
          "text" => "GERÊNCIA:\nNome/Firma: Date Test\nNIF/NIPC: 222111333\nCargo: Gerente\nOs documentos foram apresentados.",
          "hasPeople" => true
        }
      ]
    }

    stats = @importer.import_nif(@entity.tax_identifier, nif_data)
    assert_equal 1, stats.updated

    role = @entity.entity_person_roles.joins(:person).find_by(person: { tax_identifier: "222111333" })
    assert_nil role.start_date
  end

  # ── Stats ──────────────────────────────────────────────────────

  test "Stats#merge! combines two stat objects" do
    a = PublicContracts::PT::RegistoComercialImporter::Stats.new(processed: 1, updated: 1, skipped: 0, roles_created: 3)
    b = PublicContracts::PT::RegistoComercialImporter::Stats.new(processed: 2, updated: 0, skipped: 2, roles_created: 0)

    a.merge!(b)
    assert_equal 3, a.processed
    assert_equal 1, a.updated
    assert_equal 2, a.skipped
    assert_equal 3, a.roles_created
  end
end
