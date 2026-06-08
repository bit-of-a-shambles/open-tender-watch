# frozen_string_literal: true

require "test_helper"

class People::IdentityMatchServiceTest < ActiveSupport::TestCase
  test "creates high confidence match for same NIF" do
    public_role, company_role = create_roles(
      public_person: Person.create!(name: "Ana Matos", tax_identifier: "222333444", country_code: "PT"),
      company_person: Person.find_by!(tax_identifier: "222333444", country_code: "PT")
    )

    stats = People::IdentityMatchService.new.call

    assert_equal 1, stats[:upserted]
    match = PersonIdentityMatch.find_by!(match_type: "same_nif")
    assert_equal "high", match.confidence
    assert_equal 100, match.score
    assert_equal public_role.id, match.evidence["public_role_id"]
    assert_equal company_role.id, match.evidence["company_role_id"]
  end

  test "creates high confidence exact-name context match when procurement link exists" do
    public_role, company_role = create_roles(
      public_person: Person.create!(name: "Rita Carvalho", country_code: "PT"),
      company_person: Person.create!(name: "Rita Carvalho", country_code: "PT")
    )
    create_contract(authority: public_role.entity, supplier: company_role.entity)

    People::IdentityMatchService.new.call

    match = PersonIdentityMatch.find_by!(match_type: "exact_name_context")
    assert_equal "high", match.confidence
    assert_operator match.score, :>=, 80
    assert_equal 4, match.evidence["context_score"]
  end

  test "creates low confidence exact-name-only match without context" do
    create_roles(
      public_person: Person.create!(name: "Nome Comum", country_code: "PT"),
      company_person: Person.create!(name: "Nome Comum", country_code: "PT"),
      same_locality: false,
      dated_roles: false
    )

    People::IdentityMatchService.new.call

    match = PersonIdentityMatch.find_by!(match_type: "exact_name_only")
    assert_equal "low", match.confidence
    assert_equal 20, match.score
  end

  test "creates medium confidence exact-name context match for weak context" do
    create_roles(
      public_person: Person.create!(name: "Contexto Fraco", country_code: "PT"),
      company_person: Person.create!(name: "Contexto Fraco", country_code: "PT"),
      dated_roles: false
    )

    People::IdentityMatchService.new.call

    match = PersonIdentityMatch.find_by!(match_type: "exact_name_context")
    assert_equal "medium", match.confidence
    assert_equal 56, match.score
    assert_equal 1, match.evidence["context_score"]
  end

  test "is idempotent" do
    create_roles(
      public_person: Person.create!(name: "Ana Idempotente", tax_identifier: "222333445", country_code: "PT"),
      company_person: Person.find_by!(tax_identifier: "222333445", country_code: "PT")
    )

    service = People::IdentityMatchService.new
    assert_equal 1, service.call[:upserted]
    assert_no_difference "PersonIdentityMatch.count" do
      assert_equal 1, service.call[:upserted]
    end
  end

  private

  def create_roles(public_person:, company_person:, same_locality: true, dated_roles: true)
    authority = Entity.create!(
      name: "Município Match #{SecureRandom.hex(4)}",
      tax_identifier: "50#{rand(100_000_000..999_999_999)}",
      country_code: "PT",
      is_public_body: true,
      is_company: false,
      locality: "Lisboa"
    )
    supplier = Entity.create!(
      name: "Fornecedor Match #{SecureRandom.hex(4)}",
      tax_identifier: "51#{rand(100_000_000..999_999_999)}",
      country_code: "PT",
      is_public_body: false,
      is_company: true,
      locality: same_locality ? "Lisboa" : "Porto"
    )

    public_role = EntityPersonRole.create!(
      entity: authority,
      person: public_person,
      role_type: "director",
      role_label: "Diretor",
      source_name: "DRE",
      start_date: dated_roles ? Date.new(2025, 1, 1) : nil
    )
    company_role = EntityPersonRole.create!(
      entity: supplier,
      person: company_person,
      role_type: "manager",
      role_label: "Gerente",
      source_name: "Registo Comercial",
      start_date: dated_roles ? Date.new(2024, 1, 1) : nil
    )

    [ public_role, company_role ]
  end

  def create_contract(authority:, supplier:)
    contract = Contract.create!(
      external_id: "identity-match-#{SecureRandom.hex(6)}",
      country_code: "PT",
      object: "Contrato com ligação individual",
      procedure_type: "Ajuste Direto",
      publication_date: Date.new(2026, 2, 1),
      base_price: 10_000,
      contracting_entity: authority,
      data_source: data_sources(:portal_base)
    )
    ContractWinner.create!(contract: contract, entity: supplier)
  end
end
