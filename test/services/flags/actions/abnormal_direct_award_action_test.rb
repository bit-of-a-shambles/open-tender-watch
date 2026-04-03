# frozen_string_literal: true

require "test_helper"

class Flags::Actions::AbnormalDirectAwardActionTest < ActiveSupport::TestCase
  # Scenario
  # --------
  # Two contracting authorities (entities(:one) and a new authority_b) both
  # operate in CPV division "45" (first 2 chars of "45000000").
  #
  # entities(:one)  — the HIGH authority:
  #   9 "Ajuste Direto" + 1 "Concurso Público" = 90% direct award rate
  #
  # authority_b  — the LOW authority:
  #   2 "Ajuste Direto" + 8 "Concurso Público" = 20% direct award rate
  #
  # Peer median of [0.20, 0.90] = AVG = 0.55
  # entities(:one): 0.90 >= 0.80 (RATE_THRESHOLD) ✓
  #                 0.90 − 0.55 = 0.35 >= 0.25 (PEER_EXCESS) ✓  → FLAGGED
  # authority_b:    0.20 < 0.80                                   → not flagged
  #
  # The 9 direct-award contracts for entities(:one) should all receive A7 flags.
  # Note: the fixture contracts(:one) and contracts(:two) use CPV "30"/"90",
  # so they live in different CPV divisions and do not participate in the "45"
  # peer group.

  RATE_THRESHOLD = Flags::Actions::AbnormalDirectAwardAction::RATE_THRESHOLD
  PEER_EXCESS    = Flags::Actions::AbnormalDirectAwardAction::PEER_EXCESS
  FLAG_TYPE      = Flags::Actions::AbnormalDirectAwardAction::FLAG_TYPE

  def setup
    @authority_b = Entity.create!(
      name:           "Low DA Authority",
      country_code:   "PT",
      tax_identifier: "555000001",
      is_public_body: true
    )

    # entities(:one) — 9 direct awards + 1 open in CPV "45"
    @high_da_contracts = 9.times.map do |i|
      make_contract("a7-high-#{i}", entities(:one), "Ajuste Direto Regime Geral")
    end
    make_contract("a7-high-open", entities(:one), "Concurso Público")

    # authority_b — 2 direct awards + 8 open in CPV "45"
    2.times do |i|
      make_contract("a7-low-da-#{i}", @authority_b, "Ajuste Direto Regime Geral")
    end
    8.times do |i|
      make_contract("a7-low-open-#{i}", @authority_b, "Concurso Público")
    end
  end

  test "flags direct-award contracts from the high-rate authority" do
    assert_difference "Flag.count", 9 do
      Flags::Actions::AbnormalDirectAwardAction.new.call
    end

    @high_da_contracts.each do |c|
      flag = Flag.find_by(contract_id: c.id, flag_type: FLAG_TYPE)
      assert_not_nil flag, "Expected A7 flag on contract #{c.external_id}"
      assert_equal Flags::Actions::AbnormalDirectAwardAction::SEVERITY, flag.severity
      assert_equal Flags::Actions::AbnormalDirectAwardAction::SCORE,    flag.score

      rate = flag.details["direct_award_rate"].to_f
      assert_operator rate, :>=, RATE_THRESHOLD

      excess = rate - flag.details["peer_median_rate"].to_f
      assert_operator excess, :>=, PEER_EXCESS
    end
  end

  test "does not flag the low-rate authority" do
    Flags::Actions::AbnormalDirectAwardAction.new.call

    low_da_ids = Contract.where(contracting_entity: @authority_b).pluck(:id)
    assert_empty Flag.where(flag_type: FLAG_TYPE, contract_id: low_da_ids),
                 "Expected no A7 flags on the low-rate authority's contracts"
  end

  test "does not flag the open-procedure contract of the high-rate authority" do
    Flags::Actions::AbnormalDirectAwardAction.new.call

    open_contract = Contract.find_by(external_id: "a7-high-open")
    assert_nil Flag.find_by(contract_id: open_contract.id, flag_type: FLAG_TYPE),
               "Open-procedure contract should not receive an A7 flag"
  end

  test "is idempotent — calling twice does not duplicate flags" do
    Flags::Actions::AbnormalDirectAwardAction.new.call

    assert_no_difference "Flag.count" do
      Flags::Actions::AbnormalDirectAwardAction.new.call
    end
  end

  test "removes stale flags when a contract no longer qualifies" do
    Flags::Actions::AbnormalDirectAwardAction.new.call
    assert_equal 9, Flag.where(flag_type: FLAG_TYPE).count

    # Convert all high-authority contracts to open procedure so the pair
    # drops below RATE_THRESHOLD — stale flags must be removed.
    Contract.where(contracting_entity: entities(:one))
            .where("cpv_code LIKE '45%'")
            .update_all(procedure_type: "Concurso Público")

    Flags::Actions::AbnormalDirectAwardAction.new.call

    assert_equal 0, Flag.where(flag_type: FLAG_TYPE).count
  end

  test "does not flag when fewer than MIN_AUTHORITY_CONTRACTS exist" do
    # authority_b only has 10 contracts total. If we drop to 9 it still passes
    # MIN_AUTHORITY_CONTRACTS=10. Delete one to go to 9.
    Contract.where(contracting_entity: @authority_b).last.destroy

    # Rebuild the high authority as well so we only have 9 contracts for entities(:one)
    # in CPV "45". With 9 contracts for entities(:one) and 9 for authority_b we
    # are still at the boundary — but entities(:one) already has 10 (9 DA + 1 open).
    # Let's be explicit: also delete one of entities(:one)'s contracts.
    @high_da_contracts.last.destroy

    # Now entities(:one) has 9 contracts in "45" — below MIN_AUTHORITY_CONTRACTS=10.
    assert_no_difference "Flag.count" do
      Flags::Actions::AbnormalDirectAwardAction.new.call
    end
  end

  private

  def make_contract(external_id, authority, procedure_type)
    Contract.create!(
      external_id:        external_id,
      country_code:       "PT",
      object:             "Test #{external_id}",
      procedure_type:     procedure_type,
      base_price:         10_000,
      cpv_code:           "45000000",
      contracting_entity: authority,
      data_source:        data_sources(:portal_base)
    )
  end
end
