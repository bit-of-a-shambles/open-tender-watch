# frozen_string_literal: true

require "test_helper"

class Flags::Actions::SupplierConcentrationActionTest < ActiveSupport::TestCase
  # All test contracts use entities(:one) as the contracting authority.
  # The fixtures already provide:
  #   - contracts(:one), winner: entities(:one)
  #   - contracts(:two), winner: entities(:two)
  # so entities(:one) starts with 2 contracts as the contracting authority.
  # Adding 3 more contracts won by entities(:two) gives:
  #   total = 5, entities(:two) wins = 4, ratio = 0.80  (>= 0.70 threshold)
  # which triggers B2 on all 4 contracts won by entities(:two).

  MIN_NEEDED = Flags::Actions::SupplierConcentrationAction::MIN_AUTHORITY_CONTRACTS

  def create_contract_for_authority(external_id:, winner: nil)
    contract = Contract.create!(
      external_id:        external_id,
      country_code:       "PT",
      object:             "Test #{external_id}",
      procedure_type:     "Ajuste Direto",
      base_price:         5000,
      cpv_code:           "30192000",
      contracting_entity: entities(:one),
      data_source:        data_sources(:portal_base)
    )
    if winner
      ContractWinner.create!(contract: contract, entity: winner)
    end
    contract
  end

  # Build a concentrated scenario: total=5 contracts under entities(:one),
  # entities(:two) wins 4 of them (ratio 0.80). Returns the 4 winner contracts.
  def setup_concentrated_scenario
    3.times do |i|
      create_contract_for_authority(
        external_id: "b2-concentrated-#{i}",
        winner:      entities(:two)
      )
    end
    # The fixture contracts(:two) is already won by entities(:two)
    # so 4 total wins for entities(:two) out of 5 authority contracts
  end

  test "flags contracts when one supplier holds >= 70% of an authority's awards" do
    setup_concentrated_scenario

    assert_difference "Flag.count", 4 do
      Flags::Actions::SupplierConcentrationAction.new.call
    end

    # Each flagged contract should have correct details
    flag = Flag.find_by(contract_id: contracts(:two).id,
                        flag_type: Flags::Actions::SupplierConcentrationAction::FLAG_TYPE)
    assert_not_nil flag
    assert_equal Flags::Actions::SupplierConcentrationAction::SCORE,    flag.score
    assert_equal Flags::Actions::SupplierConcentrationAction::SEVERITY, flag.severity
    assert_equal entities(:two).id.to_s, flag.details["winner_entity_id"].to_s
    ratio = flag.details["concentration_ratio"].to_f
    assert_operator ratio, :>=, 0.70
  end

  test "is idempotent — calling twice does not duplicate flags" do
    setup_concentrated_scenario
    Flags::Actions::SupplierConcentrationAction.new.call

    assert_no_difference "Flag.count" do
      Flags::Actions::SupplierConcentrationAction.new.call
    end
  end

  test "does not flag when concentration is below threshold" do
    # Add 2 more contracts (one more for entities(:two), one for a new winner)
    # Total = 5, entities(:two) wins = 3/5 = 0.60 < 0.70
    other_winner = Entity.create!(
      name:           "Other Winner Ltd",
      country_code:   "PT",
      tax_identifier: "501234567",
      is_company:     true
    )

    create_contract_for_authority(external_id: "b2-below-001", winner: entities(:two))
    create_contract_for_authority(external_id: "b2-below-002", winner: other_winner)
    create_contract_for_authority(external_id: "b2-below-003", winner: other_winner)
    # Now: total = 5, entities(:two) wins = 2 (fixture contract_two + this one)
    # ratio = 2/5 = 0.40 < 0.70 → no B2 flags

    assert_no_difference "Flag.count" do
      Flags::Actions::SupplierConcentrationAction.new.call
    end
  end

  test "removes stale flags when concentration drops below threshold" do
    setup_concentrated_scenario
    Flags::Actions::SupplierConcentrationAction.new.call

    assert_equal 4, Flag.where(flag_type: Flags::Actions::SupplierConcentrationAction::FLAG_TYPE).count

    # Remove 2 of the extra contract_winners so ratio drops to 2/5=0.40 < 0.70
    extra_winners = ContractWinner.joins(:contract)
      .where(entity: entities(:two))
      .where.not(contract_id: contracts(:two).id)
      .limit(2)
    extra_winners.each do |cw|
      # Replace with a different winner so total stays at 5
      other = Entity.create!(
        name:           "Replacement #{cw.id}",
        country_code:   "PT",
        tax_identifier: "50#{cw.id}000001",
        is_company:     true
      )
      cw.update!(entity: other)
    end

    assert_difference "Flag.where(flag_type: Flags::Actions::SupplierConcentrationAction::FLAG_TYPE).count", -4 do
      Flags::Actions::SupplierConcentrationAction.new.call
    end
  end
end
