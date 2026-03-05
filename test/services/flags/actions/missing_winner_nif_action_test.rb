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
end
