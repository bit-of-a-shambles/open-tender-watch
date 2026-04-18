# frozen_string_literal: true

require "test_helper"

class CompaniesControllerPeopleRolesTest < ActionDispatch::IntegrationTest
  test "show renders normalized people roles when present" do
    entity = entities(:two)
    person = Person.create!(name: "Ana Ferreira", tax_identifier: "111222333", country_code: "PT")
    EntityPersonRole.create!(
      entity: entity,
      person: person,
      role_type: "manager",
      role_label: "Gerente",
      source_name: "Registo Comercial"
    )

    get company_url(entity)
    assert_response :success
    assert_includes response.body, "Ana Ferreira"
    assert_includes response.body, "Gerente"
    assert_includes response.body, "111222333"
  end
end