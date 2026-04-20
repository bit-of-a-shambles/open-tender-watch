# frozen_string_literal: true

require "test_helper"

class EntityPersonRoleTest < ActiveSupport::TestCase
  setup do
    @entity = entities(:two)
    @person = Person.create!(name: "Ana Ferreira", tax_identifier: "111222333", country_code: "PT")
  end

  test "valid role saves successfully" do
    role = EntityPersonRole.new(
      entity: @entity,
      person: @person,
      role_type: "manager",
      role_label: "Gerente",
      source_name: "Registo Comercial"
    )

    assert role.valid?
    assert role.save
  end

  test "invalid without role_type" do
    role = EntityPersonRole.new(entity: @entity, person: @person, source_name: "Registo Comercial")
    assert_not role.valid?
  end

  test "invalid with unsupported role_type" do
    role = EntityPersonRole.new(entity: @entity, person: @person, role_type: "wizard", source_name: "Registo Comercial")
    assert_not role.valid?
  end

  test "delegates person attributes and role label" do
    role = EntityPersonRole.create!(
      entity: @entity,
      person: @person,
      role_type: "manager",
      role_label: "Gerente",
      source_name: "Registo Comercial"
    )

    assert_equal "Ana Ferreira", role.name
    assert_equal "111222333", role.tax_identifier
    assert_equal "PT", role.country_code
    assert_equal "Gerente", role.role
  end

  test "falls back to humanized role when label missing" do
    role = EntityPersonRole.create!(
      entity: @entity,
      person: @person,
      role_type: "partner_shareholder",
      source_name: "Registo Comercial"
    )

    assert_equal "Partner shareholder", role.role
  end

  test "sort priority defaults unknown role to lowest priority" do
    role = EntityPersonRole.create!(
      entity: @entity,
      person: @person,
      role_type: "unknown",
      source_name: "Registo Comercial"
    )

    assert_equal EntityPersonRole::ROLE_PRIORITY["unknown"], role.sort_priority
  end
end
