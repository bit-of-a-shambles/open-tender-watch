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
    # Public access: names are pseudonymised
    assert_not_includes response.body, "Ana Ferreira"
    assert_not_includes response.body, "111222333"
    assert_includes response.body, "[P-"
    assert_includes response.body, "Gerente"
  end

  test "show reveals people roles with journalist token" do
    entity = entities(:two)
    person = Person.create!(name: "Ana Ferreira", tax_identifier: "111222333", country_code: "PT")
    EntityPersonRole.create!(
      entity: entity,
      person: person,
      role_type: "manager",
      role_label: "Gerente",
      source_name: "Registo Comercial"
    )

    # Authenticate
    token = access_tokens(:one)
    post access_token_url, params: { token: token.token }

    get company_url(entity)
    assert_response :success
    assert_includes response.body, "Ana Ferreira"
    assert_includes response.body, "111222333"
    assert_includes response.body, "Gerente"
  end
end