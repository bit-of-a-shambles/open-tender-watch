require "test_helper"

class EntityTest < ActiveSupport::TestCase
  test "valid entity" do
    entity = Entity.new(name: "Test Entity", tax_identifier: "123456789", country_code: "PT")
    assert entity.valid?
  end

  test "invalid without name" do
    entity = Entity.new(tax_identifier: "123456789", country_code: "PT")
    assert_not entity.valid?
    assert entity.errors.added?(:name, :blank)
  end

  test "invalid without tax_identifier" do
    entity = Entity.new(name: "Test Entity", country_code: "PT")
    assert_not entity.valid?
  end

  test "invalid without country_code" do
    entity = Entity.new(name: "Test Entity", tax_identifier: "123456789")
    entity.country_code = ""
    assert_not entity.valid?
  end

  test "tax_identifier must be unique within country" do
    existing = entities(:one)
    duplicate = Entity.new(
      name:           "Other",
      tax_identifier: existing.tax_identifier,
      country_code:   existing.country_code
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors.details[:tax_identifier].map { |e| e[:error] }, :taken
  end

  test "same tax_identifier allowed in different countries" do
    existing = entities(:one)
    other_country = Entity.new(
      name:           "Spanish clone",
      tax_identifier: existing.tax_identifier,
      country_code:   "ES"
    )
    assert other_country.valid?
  end

  test "has many contracts_as_contracting_entity" do
    assert_respond_to entities(:one), :contracts_as_contracting_entity
  end

  test "has many contract_winners" do
    assert_respond_to entities(:one), :contract_winners
  end

  test "has many contract_bidders" do
    assert_respond_to entities(:one), :contract_bidders
  end

  test "has many contracts_won through contract_winners" do
    assert_respond_to entities(:one), :contracts_won
  end

  test "has many contracts_bid_on through contract_bidders" do
    assert_respond_to entities(:one), :contracts_bid_on
  end

  test "current_people_roles falls back to company directors when normalized roles absent" do
    names = entities(:two).current_people_roles.map(&:name)
    assert_includes names, company_directors(:one).name
    assert_includes names, company_directors(:two).name
  end

  test "current_people_roles prefers normalized active roles sorted by priority" do
    entity = entities(:two)
    director = Person.create!(name: "Zara Director", country_code: "PT")
    manager = Person.create!(name: "Ana Manager", country_code: "PT")

    EntityPersonRole.create!(entity:, person: manager, role_type: "manager", role_label: "Gerente", source_name: "Registo Comercial")
    EntityPersonRole.create!(entity:, person: director, role_type: "director", role_label: "Diretora", source_name: "Registo Comercial")

    assert_equal [ "Zara Director", "Ana Manager" ], entity.current_people_roles.map(&:name)
  end

  test "all_people_roles returns active then inactive sorted by priority" do
    entity = entities(:two)
    active = Person.create!(name: "Ana Active", country_code: "PT")
    former = Person.create!(name: "Bob Former", country_code: "PT")

    EntityPersonRole.create!(entity:, person: active, role_type: "manager", role_label: "Gerente", source_name: "Registo Comercial", active: true, start_date: Date.new(2020, 1, 1))
    EntityPersonRole.create!(entity:, person: former, role_type: "manager", role_label: "Gerente", source_name: "Registo Comercial", active: false, start_date: Date.new(2015, 1, 1), end_date: Date.new(2019, 12, 31))

    roles = entity.all_people_roles
    assert_equal [ "Ana Active", "Bob Former" ], roles.map(&:name)
    assert roles.first.active?
    assert_not roles.last.active?
  end

  test "all_people_roles falls back to company directors when no person roles" do
    names = entities(:two).all_people_roles.map(&:name)
    assert_includes names, company_directors(:one).name
  end

  test "current_directors_and_officers delegates to current_people_roles" do
    assert_equal entities(:two).current_people_roles, entities(:two).current_directors_and_officers
  end
end
