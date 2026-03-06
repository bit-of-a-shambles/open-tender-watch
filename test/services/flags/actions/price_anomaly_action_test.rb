require "test_helper"

class Flags::Actions::PriceAnomalyActionTest < ActiveSupport::TestCase
  def create_contract(external_id:, base_price:, total_effective_price:)
    Contract.create!(
      external_id: external_id,
      country_code: "PT",
      object: "Contrato #{external_id}",
      procedure_type: "Ajuste Direto",
      base_price: base_price,
      total_effective_price: total_effective_price,
      contracting_entity: entities(:one),
      data_source: data_sources(:portal_base)
    )
  end

  # ---------------------------------------------------------------------------
  # A9_PRICE_ANOMALY — price increases
  # ---------------------------------------------------------------------------

  test "creates medium A9_PRICE_ANOMALY when ratio > 1.5 and <= 2.0" do
    c = create_contract(external_id: "a9-med", base_price: 1000, total_effective_price: 1600)

    assert_difference "Flag.count", 1 do
      assert_equal 1, Flags::Actions::PriceAnomalyAction.new.call
    end

    flag = Flag.find_by!(contract_id: c.id, flag_type: "A9_PRICE_ANOMALY")
    assert_equal "medium", flag.severity
    assert_equal Flags::Actions::PriceAnomalyAction::SCORE_MED, flag.score
    assert_in_delta 1.6, flag.details["ratio"].to_f, 0.001
    assert_equal "increase", flag.details["direction"]
  end

  test "creates high A9_PRICE_ANOMALY when ratio >= 2.0" do
    c = create_contract(external_id: "a9-high", base_price: 1000, total_effective_price: 2100)

    assert_difference "Flag.count", 1 do
      Flags::Actions::PriceAnomalyAction.new.call
    end

    flag = Flag.find_by!(contract_id: c.id, flag_type: "A9_PRICE_ANOMALY")
    assert_equal "high", flag.severity
    assert_equal Flags::Actions::PriceAnomalyAction::SCORE_HIGH, flag.score
    assert_in_delta 2.1, flag.details["ratio"].to_f, 0.001
    assert_equal "increase", flag.details["direction"]
  end

  # ---------------------------------------------------------------------------
  # A9_PRICE_REDUCTION — price reductions
  # ---------------------------------------------------------------------------

  test "creates low A9_PRICE_REDUCTION when ratio < 0.5" do
    c = create_contract(external_id: "a9-red", base_price: 1000, total_effective_price: 400)

    assert_difference "Flag.count", 1 do
      assert_equal 1, Flags::Actions::PriceAnomalyAction.new.call
    end

    flag = Flag.find_by!(contract_id: c.id, flag_type: "A9_PRICE_REDUCTION")
    assert_equal "low", flag.severity
    assert_equal Flags::Actions::PriceAnomalyAction::SCORE_LOW, flag.score
    assert_in_delta 0.4, flag.details["ratio"].to_f, 0.001
    assert_equal "reduction", flag.details["direction"]
  end

  test "reduction and increase on same run produce separate flag types" do
    r = create_contract(external_id: "a9-r", base_price: 1000, total_effective_price: 400)
    i = create_contract(external_id: "a9-i", base_price: 1000, total_effective_price: 1800)

    assert_difference "Flag.count", 2 do
      assert_equal 2, Flags::Actions::PriceAnomalyAction.new.call
    end

    assert Flag.exists?(contract_id: r.id, flag_type: "A9_PRICE_REDUCTION")
    assert Flag.exists?(contract_id: i.id, flag_type: "A9_PRICE_ANOMALY")
  end

  # ---------------------------------------------------------------------------
  # No-fire cases
  # ---------------------------------------------------------------------------

  test "does not fire when ratio is within [0.5, 1.5]" do
    create_contract(external_id: "a9-ok-high", base_price: 1000, total_effective_price: 1500)
    create_contract(external_id: "a9-ok-low",  base_price: 1000, total_effective_price: 500)
    create_contract(external_id: "a9-ok-mid",  base_price: 1000, total_effective_price: 900)

    assert_no_difference "Flag.count" do
      assert_equal 0, Flags::Actions::PriceAnomalyAction.new.call
    end
  end

  test "does not fire when base_price is nil" do
    create_contract(external_id: "a9-nil-base", base_price: nil, total_effective_price: 500)
    assert_no_difference("Flag.count") { Flags::Actions::PriceAnomalyAction.new.call }
  end

  test "does not fire when total_effective_price is nil" do
    create_contract(external_id: "a9-nil-total", base_price: 1000, total_effective_price: nil)
    assert_no_difference("Flag.count") { Flags::Actions::PriceAnomalyAction.new.call }
  end

  test "does not fire when base_price is zero" do
    create_contract(external_id: "a9-zero-base", base_price: 0, total_effective_price: 500)
    assert_no_difference("Flag.count") { Flags::Actions::PriceAnomalyAction.new.call }
  end

  # ---------------------------------------------------------------------------
  # Idempotency & stale cleanup
  # ---------------------------------------------------------------------------

  test "is idempotent for price increase" do
    create_contract(external_id: "a9-idem-inc", base_price: 1000, total_effective_price: 2000)
    action = Flags::Actions::PriceAnomalyAction.new
    assert_equal 1, action.call
    assert_no_difference("Flag.count") { assert_equal 1, action.call }
  end

  test "is idempotent for price reduction" do
    create_contract(external_id: "a9-idem-red", base_price: 1000, total_effective_price: 300)
    action = Flags::Actions::PriceAnomalyAction.new
    assert_equal 1, action.call
    assert_no_difference("Flag.count") { assert_equal 1, action.call }
  end

  test "removes stale A9_PRICE_ANOMALY flags when contract corrected" do
    c = create_contract(external_id: "a9-stale-inc", base_price: 1000, total_effective_price: 2000)
    action = Flags::Actions::PriceAnomalyAction.new
    action.call
    assert_equal 1, Flag.where(contract_id: c.id, flag_type: "A9_PRICE_ANOMALY").count

    c.update!(total_effective_price: 1100)
    assert_equal 0, action.call
    assert_equal 0, Flag.where(contract_id: c.id).count
  end

  test "removes stale A9_PRICE_REDUCTION flags when contract corrected" do
    c = create_contract(external_id: "a9-stale-red", base_price: 1000, total_effective_price: 300)
    action = Flags::Actions::PriceAnomalyAction.new
    action.call
    assert_equal 1, Flag.where(contract_id: c.id, flag_type: "A9_PRICE_REDUCTION").count

    c.update!(total_effective_price: 700)
    assert_equal 0, action.call
    assert_equal 0, Flag.where(contract_id: c.id).count
  end

  test "price increase reclassifies to high severity on second run" do
    c = create_contract(external_id: "a9-reclass", base_price: 1000, total_effective_price: 1700)
    action = Flags::Actions::PriceAnomalyAction.new
    action.call
    assert_equal "medium", Flag.find_by!(contract_id: c.id, flag_type: "A9_PRICE_ANOMALY").severity

    c.update!(total_effective_price: 2500)
    action.call
    assert_equal "high", Flag.find_by!(contract_id: c.id, flag_type: "A9_PRICE_ANOMALY").severity
  end

  # ---------------------------------------------------------------------------
  # Sense-check regressions — patterns found in production data (2026-03-06)
  # ---------------------------------------------------------------------------

  test "fires A9_PRICE_REDUCTION for extreme ratio (base price entered in wrong units)" do
    # Seen in BASE production data: drug/medicine contracts where base_price
    # appears to have been entered in cents rather than euros, or with extra
    # zeroes (e.g. €147,456,136,800 base vs €147,456 effective — ratio ~0.000001).
    # The A9_PRICE_REDUCTION flag must catch these extreme mismatches.
    c = create_contract(
      external_id:           "a9-extreme-ratio",
      base_price:            147_456_136_800,
      total_effective_price: 147_456
    )

    assert_difference "Flag.count", 1 do
      Flags::Actions::PriceAnomalyAction.new.call
    end

    flag = Flag.find_by!(contract_id: c.id, flag_type: "A9_PRICE_REDUCTION")
    assert ratio = flag.details["ratio"].to_f
    assert ratio < 0.001,
           "expected near-zero ratio for extreme data entry error, got #{ratio}"
    assert_equal "reduction", flag.details["direction"]
  end

  test "does not fire A9 for concession contract where both prices are negative and within normal ratio" do
    # Concession contracts (billboard licences, bar franchises, parking lots)
    # record a negative base_price because the private entity pays the public body.
    # When both prices agree in sign and magnitude (ratio within [0.5, 1.5]), no flag.
    create_contract(
      external_id:           "a9-concession-ok",
      base_price:            -54_000,
      total_effective_price: -50_000  # ratio = 0.926 — within [0.5, 1.5]
    )

    assert_no_difference "Flag.count" do
      Flags::Actions::PriceAnomalyAction.new.call
    end
  end

  test "fires A9_PRICE_REDUCTION when negative base_price has zero effective price" do
    # Edge case: concession contract where the final payment was zero.
    # ratio = 0 / -54000 = 0.0, which is below the 0.5 RATIO_MIN threshold.
    # The current implementation fires a low-severity reduction flag here —
    # this is a known false-positive for concession contracts (no effective price).
    c = create_contract(
      external_id:           "a9-concession-zero-eff",
      base_price:            -54_000,
      total_effective_price: 0
    )

    assert_difference "Flag.count", 1 do
      Flags::Actions::PriceAnomalyAction.new.call
    end

    flag = Flag.find_by!(contract_id: c.id, flag_type: "A9_PRICE_REDUCTION")
    assert_equal "low", flag.severity
  end
end
