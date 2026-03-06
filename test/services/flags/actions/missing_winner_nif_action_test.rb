# frozen_string_literal: true

require "test_helper"

class Flags::Actions::MissingWinnerNifActionTest < ActiveSupport::TestCase
  def create_contract(external_id:, **attrs)
    Contract.create!(
      external_id:        external_id,
      country_code:       "PT",
      object:             "Test #{external_id}",
      procedure_type:     "Ajuste Direto",
      base_price:         1000,
      contracting_entity: entities(:one),
      data_source:        data_sources(:portal_base),
      **attrs
    )
  end

  def create_winner_entity(tax_identifier: nil)
    entity = Entity.new(
      name:           "Winner No NIF #{SecureRandom.hex(4)}",
      country_code:   "PT",
      tax_identifier: tax_identifier,
      is_company:     true
    )
    entity.save!(validate: false)
    entity
  end

  test "creates a flag for a contract whose winner has no tax_identifier" do
    entity   = create_winner_entity(tax_identifier: nil)
    contract = create_contract(external_id: "c1-test-001")
    ContractWinner.create!(contract: contract, entity: entity)

    assert_difference "Flag.count", 1 do
      Flags::Actions::MissingWinnerNifAction.new.call
    end

    flag = Flag.find_by(contract_id: contract.id,
                        flag_type: Flags::Actions::MissingWinnerNifAction::FLAG_TYPE)
    assert_not_nil flag
    assert_equal Flags::Actions::MissingWinnerNifAction::SCORE,    flag.score
    assert_equal Flags::Actions::MissingWinnerNifAction::SEVERITY, flag.severity
  end

  test "creates a flag for a contract whose winner has an empty tax_identifier" do
    entity   = create_winner_entity(tax_identifier: "")
    contract = create_contract(external_id: "c1-test-002")
    ContractWinner.create!(contract: contract, entity: entity)

    assert_difference "Flag.count", 1 do
      Flags::Actions::MissingWinnerNifAction.new.call
    end
  end

  test "is idempotent — calling twice does not duplicate flags" do
    entity   = create_winner_entity(tax_identifier: nil)
    contract = create_contract(external_id: "c1-test-003")
    ContractWinner.create!(contract: contract, entity: entity)

    Flags::Actions::MissingWinnerNifAction.new.call

    assert_no_difference "Flag.count" do
      Flags::Actions::MissingWinnerNifAction.new.call
    end
  end

  test "removes stale flags when the winner NIF is filled in" do
    entity   = create_winner_entity(tax_identifier: nil)
    contract = create_contract(external_id: "c1-test-004")
    ContractWinner.create!(contract: contract, entity: entity)

    Flags::Actions::MissingWinnerNifAction.new.call
    assert_equal 1, Flag.where(flag_type: Flags::Actions::MissingWinnerNifAction::FLAG_TYPE,
                               contract_id: contract.id).count

    # Fix the NIF
    entity.update!(tax_identifier: "500000001")

    assert_difference "Flag.where(flag_type: Flags::Actions::MissingWinnerNifAction::FLAG_TYPE).count", -1 do
      Flags::Actions::MissingWinnerNifAction.new.call
    end
  end

  test "does not flag contracts whose all winners have a tax_identifier" do
    entity   = create_winner_entity(tax_identifier: "500000002")
    contract = create_contract(external_id: "c1-test-005")
    ContractWinner.create!(contract: contract, entity: entity)

    assert_no_difference "Flag.count" do
      Flags::Actions::MissingWinnerNifAction.new.call
    end
  end

  # ---------------------------------------------------------------------------
  # C1b — No winner recorded for an awarded contract
  # ---------------------------------------------------------------------------
  #
  # Investigation found ~217K BASE contracts (primarily "Ajuste Direto Regime
  # Geral") that carry no ContractWinner rows at all. This is a known BASE data
  # quality pattern: authorities publish the award notice without completing the
  # supplier fields. When a contract has a positive effective price (it was
  # awarded) but no winner is recorded, that is flagged as C1.

  test "flags an awarded contract (positive effective_price) with no winners" do
    contract = create_contract(
      external_id:          "c1-no-winner-001",
      total_effective_price: BigDecimal("50000")
    )

    assert_difference "Flag.count", 1 do
      Flags::Actions::MissingWinnerNifAction.new.call
    end

    flag = Flag.find_by!(contract_id: contract.id,
                         flag_type: Flags::Actions::MissingWinnerNifAction::FLAG_TYPE)
    assert_equal Flags::Actions::MissingWinnerNifAction::SCORE,    flag.score
    assert_equal Flags::Actions::MissingWinnerNifAction::SEVERITY, flag.severity
    assert_match(/no winner recorded/, flag.details["rule"])
  end

  test "does not flag a winner-less contract when effective_price is zero or nil" do
    # Zero-price contracts (e.g. framework agreements, pre-award notices) may legitimately
    # have no winner yet. Only positive effective_price indicates actual award.
    create_contract(external_id: "c1-no-winner-zero-price",  total_effective_price: BigDecimal("0"))
    create_contract(external_id: "c1-no-winner-nil-price",   total_effective_price: nil)

    assert_no_difference "Flag.count" do
      Flags::Actions::MissingWinnerNifAction.new.call
    end
  end

  test "blank-NIF case takes precedence when contract also has no-winner match" do
    # A contract with a blank-NIF winner would also be in the no_winner_awarded_scope
    # if it had a separate positive effective_price entry. Ensure we count it once.
    entity   = create_winner_entity(tax_identifier: nil)
    contract = create_contract(external_id: "c1-both-cases", total_effective_price: BigDecimal("1000"))
    ContractWinner.create!(contract: contract, entity: entity)

    assert_difference "Flag.count", 1 do
      Flags::Actions::MissingWinnerNifAction.new.call
    end

    # Only one flag, and rule text matches blank-NIF (not no-winner)
    flag = Flag.find_by!(contract_id: contract.id,
                         flag_type: Flags::Actions::MissingWinnerNifAction::FLAG_TYPE)
    assert_match(/missing winner NIF/, flag.details["rule"])
  end

  test "no-winner flag is cleaned up when winners are later added" do
    contract = create_contract(
      external_id:          "c1-no-winner-stale",
      total_effective_price: BigDecimal("25000")
    )

    action = Flags::Actions::MissingWinnerNifAction.new
    action.call
    assert Flag.exists?(contract_id: contract.id,
                        flag_type: Flags::Actions::MissingWinnerNifAction::FLAG_TYPE)

    # Add a winner with a valid NIF
    entity = create_winner_entity(tax_identifier: "500100200")
    ContractWinner.create!(contract: contract, entity: entity)

    assert_difference "Flag.count", -1 do
      action.call
    end

    assert_not Flag.exists?(contract_id: contract.id,
                            flag_type: Flags::Actions::MissingWinnerNifAction::FLAG_TYPE)
  end
end
