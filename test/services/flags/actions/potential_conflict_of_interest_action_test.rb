# frozen_string_literal: true

require "test_helper"

class Flags::Actions::PotentialConflictOfInterestActionTest < ActiveSupport::TestCase
  test "flags contracts for actionable shared individual links" do
    contract, match = create_conflict_setup

    assert_difference "Flag.count", 1 do
      assert_equal 1, Flags::Actions::PotentialConflictOfInterestAction.new.call
    end

    flag = Flag.find_by!(contract: contract, flag_type: "C7_POTENTIAL_CONFLICT_OF_INTEREST")
    assert_equal "high", flag.severity
    assert_equal 65, flag.score
    assert_equal match.id, flag.details["match_id"]
    assert_equal "c7_shared_individual_link", flag.details["rule"]
    assert_equal "Fornecedor C7", flag.details["supplier_name"]
  end

  test "does not flag rejected or low confidence matches" do
    create_conflict_setup(confidence: "low")
    create_conflict_setup(review_status: "rejected", suffix: "rejected")

    assert_no_difference "Flag.count" do
      assert_equal 0, Flags::Actions::PotentialConflictOfInterestAction.new.call
    end
  end

  test "does not flag when role dates do not cover contract date" do
    create_conflict_setup(contract_date: Date.new(2026, 1, 1), role_end_date: Date.new(2025, 12, 31))

    assert_no_difference "Flag.count" do
      assert_equal 0, Flags::Actions::PotentialConflictOfInterestAction.new.call
    end
  end

  test "removes stale flags" do
    _contract, match = create_conflict_setup
    action = Flags::Actions::PotentialConflictOfInterestAction.new
    assert_equal 1, action.call

    match.update!(review_status: "rejected")

    assert_equal 0, action.call
    assert_equal 0, Flag.where(flag_type: "C7_POTENTIAL_CONFLICT_OF_INTEREST").count
  end

  test "deduplicates multiple matches for the same contract" do
    contract, = create_conflict_setup
    original = PersonIdentityMatch.first
    duplicate_person = Person.create!(name: "Ana Duplicada", country_code: "PT")
    duplicate = PersonIdentityMatch.create!(
      left_person: duplicate_person,
      right_person: duplicate_person,
      match_type: "exact_name_context",
      confidence: "high",
      score: 80,
      evidence: original.evidence
    )

    assert_equal "unreviewed", duplicate.review_status
    assert_difference "Flag.count", 1 do
      assert_equal 1, Flags::Actions::PotentialConflictOfInterestAction.new.call
    end
    assert Flag.exists?(contract: contract, flag_type: "C7_POTENTIAL_CONFLICT_OF_INTEREST")
  end

  private

  def create_conflict_setup(confidence: "high", review_status: "unreviewed", contract_date: Date.new(2026, 1, 1), role_end_date: nil, suffix: SecureRandom.hex(4))
    authority = Entity.create!(
      name: "Município C7 #{suffix}",
      tax_identifier: "70#{rand(100_000_000..999_999_999)}",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    supplier = Entity.create!(
      name: "Fornecedor C7",
      tax_identifier: "71#{rand(100_000_000..999_999_999)}",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    person = Person.create!(name: "Ana Conflito #{suffix}", country_code: "PT")
    public_role = EntityPersonRole.create!(
      entity: authority,
      person: person,
      role_type: "director",
      role_label: "Diretora",
      source_name: "DRE",
      start_date: Date.new(2025, 1, 1),
      end_date: role_end_date,
      active: role_end_date.nil?
    )
    company_role = EntityPersonRole.create!(
      entity: supplier,
      person: person,
      role_type: "manager",
      role_label: "Gerente",
      source_name: "Registo Comercial",
      start_date: Date.new(2024, 1, 1)
    )
    contract = Contract.create!(
      external_id: "c7-#{suffix}",
      country_code: "PT",
      object: "Contrato C7",
      procedure_type: "Ajuste Direto",
      publication_date: contract_date,
      base_price: 10_000,
      contracting_entity: authority,
      data_source: data_sources(:portal_base)
    )
    ContractWinner.create!(contract: contract, entity: supplier)
    match = PersonIdentityMatch.create!(
      left_person: person,
      right_person: person,
      match_type: "same_nif",
      confidence: confidence,
      score: 100,
      review_status: review_status,
      evidence: {
        "public_role_id" => public_role.id,
        "company_role_id" => company_role.id
      }
    )

    [ contract, match ]
  end
end
