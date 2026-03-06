require "test_helper"

class Flags::Actions::BenfordLawActionTest < ActiveSupport::TestCase
  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  # Creates contracts for the given entity with the supplied base_price values.
  # Uses entities(:two) by default as it carries no fixture contracts, keeping
  # chi-square calculations predictable.
  # Also updates entity.contract_count so the BenfordLawAction pre-filter works
  # (the action uses the pre-computed column for performance).
  def create_contracts(prices:, entity: entities(:two), prefix: "benford")
    contracts = prices.each_with_index.map do |price, i|
      Contract.create!(
        external_id:          "#{prefix}-#{i}",
        country_code:         "PT",
        object:               "Contrato #{prefix}-#{i}",
        procedure_type:       "Ajuste Direto",
        base_price:           price.to_d,
        contracting_entity:   entity,
        data_source:          data_sources(:portal_base)
      )
    end
    # Keep pre-computed count in sync so the action's pre-filter includes this entity
    entity.update_column(:contract_count, entity.contracts_as_contracting_entity.count)
    contracts
  end

  # 20 prices approximating Benford's distribution (chi-square ~1.3, well under 15.507)
  BENFORD_PRICES = [
    1_000, 1_100, 1_200, 1_300, 1_400, 1_500,   # 6 × leading 1  (~30%)
    2_100, 2_200, 2_300, 2_400,                   # 4 × leading 2  (~20%)
    3_100, 3_200, 3_300,                           # 3 × leading 3  (~15%)
    4_100, 4_200,                                  # 2 × leading 4  (~10%)
    5_100, 5_200,                                  # 2 × leading 5  (~10%)
    6_100,                                         # 1 × leading 6  (~5%)
    7_100,                                         # 1 × leading 7  (~5%)
    8_100                                          # 1 × leading 8  (~5%)
  ].freeze

  # -------------------------------------------------------------------
  # Tests — flagging behaviour
  # -------------------------------------------------------------------

  test "does not flag entity with fewer than MIN_SAMPLE contracts" do
    # 19 contracts all starting with '8' — clearly non-Benford but below threshold
    create_contracts(prices: Array.new(19) { |i| 8_000 + i }, prefix: "benford-small")

    assert_no_difference "Flag.count" do
      result = Flags::Actions::BenfordLawAction.new.call
      assert_equal 0, result
    end
  end

  test "flags ONE representative contract of entity whose prices strongly deviate from Benford's law" do
    # 25 contracts all starting with '9' — chi-square >> 15.507
    # Only the highest-priced contract is flagged (one per entity).
    contracts = create_contracts(prices: Array.new(25) { |i| 9_000 + i }, prefix: "benford-anomaly")

    assert_difference "Flag.count", 1 do
      result = Flags::Actions::BenfordLawAction.new.call
      assert_equal 1, result
    end

    flag = Flag.find_by!(flag_type: "B5_BENFORD_DEVIATION")
    chi2 = flag.details["chi2"].to_f
    assert chi2 > 15.507, "Expected chi2 > 15.507, got #{chi2}"
    assert_equal "25",    flag.details["sample_size"]
    assert_includes %w[medium high], flag.severity
    assert flag.score > 0
    # Flag is on the highest-priced contract
    max_contract = contracts.max_by(&:base_price)
    assert_equal max_contract.id, flag.contract_id
  end

  test "high severity when chi-square exceeds p=0.01 threshold" do
    # All 25 prices start with '9': chi-square far exceeds CHI2_P01 (20.09)
    create_contracts(prices: Array.new(25) { |i| 9_000 + i }, prefix: "benford-high")

    Flags::Actions::BenfordLawAction.new.call

    flag = Flag.find_by!(flag_type: "B5_BENFORD_DEVIATION")
    assert flag.details["chi2"].to_f > 20.09, "Expected chi2 > 20.09 for high severity"
    assert_equal "high", flag.severity
    assert_equal Flags::Actions::BenfordLawAction::SCORE_HIGH, flag.score
  end

  test "does not flag entity with roughly Benford-distributed prices" do
    create_contracts(prices: BENFORD_PRICES, prefix: "benford-ok")

    assert_no_difference "Flag.count" do
      result = Flags::Actions::BenfordLawAction.new.call
      assert_equal 0, result
    end
  end

  test "does not fire on contracts with base_price below 1" do
    # 25 contracts all have sub-unit prices — excluded from Benford analysis
    create_contracts(prices: Array.new(25) { |i| BigDecimal("0.#{(i % 9) + 1}") }, prefix: "benford-subunit")

    assert_no_difference "Flag.count" do
      Flags::Actions::BenfordLawAction.new.call
    end
  end

  test "is idempotent — calling twice does not duplicate flags" do
    create_contracts(prices: Array.new(25) { |i| 7_000 + i }, prefix: "benford-idem")

    action = Flags::Actions::BenfordLawAction.new

    assert_difference "Flag.count", 1 do
      assert_equal 1, action.call
    end

    assert_no_difference "Flag.count" do
      assert_equal 1, action.call
    end
  end

  test "flag details include observed digit distribution" do
    create_contracts(prices: Array.new(25) { |i| 9_000 + i }, prefix: "benford-details")

    Flags::Actions::BenfordLawAction.new.call

    flag = Flag.find_by!(flag_type: "B5_BENFORD_DEVIATION")
    observed = flag.details["observed"]
    assert_not_nil observed, "details['observed'] should be present"
    assert_equal 25, observed["9"].to_i
    assert_equal 0,  observed["1"].to_i
  end

  test "stale flags are removed when entity contracts drop below MIN_SAMPLE" do
    contracts = create_contracts(prices: Array.new(25) { |i| 8_000 + i }, prefix: "benford-stale")

    Flags::Actions::BenfordLawAction.new.call
    assert_equal 1, Flag.where(flag_type: "B5_BENFORD_DEVIATION").count

    # Remove enough contracts to drop below MIN_SAMPLE and update pre-computed count
    contracts.last(6).each(&:destroy)
    entities(:two).update_column(:contract_count, entities(:two).contracts_as_contracting_entity.count)

    Flags::Actions::BenfordLawAction.new.call
    assert_equal 0, Flag.where(flag_type: "B5_BENFORD_DEVIATION").count
  end

  test "stale flags are removed when prices become Benford-compliant" do
    contracts = create_contracts(prices: Array.new(25) { |i| 9_000 + i }, prefix: "benford-correct")

    Flags::Actions::BenfordLawAction.new.call
    assert_equal 1, Flag.where(flag_type: "B5_BENFORD_DEVIATION").count

    # Replace all prices with a Benford-following distribution
    contracts.each_with_index do |c, i|
      c.update!(base_price: BENFORD_PRICES[i % BENFORD_PRICES.size])
    end

    Flags::Actions::BenfordLawAction.new.call
    assert_equal 0, Flag.where(flag_type: "B5_BENFORD_DEVIATION").count
  end

  test "handles multiple entities independently" do
    # entity(:two)  — anomalous (all 9s) → 1 flag
    create_contracts(prices: Array.new(25) { |i| 9_000 + i }, prefix: "benford-a", entity: entities(:two))
    # entity(:one) has only 2 fixture contracts (base_price 18000, 25000) → below MIN_SAMPLE; safe

    assert_difference "Flag.count", 1 do
      Flags::Actions::BenfordLawAction.new.call
    end
  end

  # -------------------------------------------------------------------
  # Tests — BenfordAnalysis records
  # -------------------------------------------------------------------

  test "creates BenfordAnalysis record for anomalous entity" do
    create_contracts(prices: Array.new(25) { |i| 9_000 + i }, prefix: "ba-anom")

    Flags::Actions::BenfordLawAction.new.call

    analysis = BenfordAnalysis.find_by(entity: entities(:two))
    assert_not_nil analysis
    assert analysis.flagged
    assert_equal "high", analysis.severity
    assert analysis.chi_square > 15.507
    assert_equal 25, analysis.sample_size
  end

  test "creates BenfordAnalysis record for non-anomalous entity" do
    create_contracts(prices: BENFORD_PRICES, prefix: "ba-ok")

    Flags::Actions::BenfordLawAction.new.call

    analysis = BenfordAnalysis.find_by(entity: entities(:two))
    assert_not_nil analysis
    assert_not analysis.flagged
    assert_nil analysis.severity
    assert analysis.chi_square < 15.507
  end

  test "BenfordAnalysis digit_distribution contains correct counts" do
    prices = Array.new(20) { |i| 9_000 + i }   # 20 × leading-9
    create_contracts(prices: prices, prefix: "ba-dist")

    Flags::Actions::BenfordLawAction.new.call

    analysis = BenfordAnalysis.find_by!(entity: entities(:two))
    dist = analysis.digit_distribution
    assert_equal 20, dist["9"].to_i
    assert_equal 0,  dist["1"].to_i
  end

  test "does not create BenfordAnalysis for entity below MIN_SAMPLE" do
    create_contracts(prices: Array.new(19) { |i| 9_000 + i }, prefix: "ba-small")

    Flags::Actions::BenfordLawAction.new.call

    assert_nil BenfordAnalysis.find_by(entity: entities(:two))
  end

  test "BenfordAnalysis representative_contract_id points to highest-priced contract" do
    contracts = create_contracts(prices: Array.new(25) { |i| 9_000 + i }, prefix: "ba-rep")
    highest   = contracts.max_by(&:base_price)

    Flags::Actions::BenfordLawAction.new.call

    analysis = BenfordAnalysis.find_by!(entity: entities(:two))
    assert_equal highest.id, analysis.representative_contract_id
  end

  test "BenfordAnalysis prefers awarded contract over open tender as representative" do
    # Create 24 open-tender (no celebration_date) contracts and 1 awarded with lower price
    open_prices   = Array.new(24) { |i| 9_000 + i }
    create_contracts(prices: open_prices, prefix: "ba-open-tender", entity: entities(:two))
    awarded = Contract.create!(
      external_id:        "ba-awarded",
      country_code:       "PT",
      object:             "Awarded contract",
      procedure_type:     "Concurso Público",
      base_price:         5_000.to_d,  # lower price but has celebration_date
      celebration_date:   Date.new(2025, 1, 1),
      contracting_entity: entities(:two),
      data_source:        data_sources(:portal_base)
    )
    entities(:two).update_column(:contract_count, entities(:two).contracts_as_contracting_entity.count)

    Flags::Actions::BenfordLawAction.new.call

    analysis = BenfordAnalysis.find_by!(entity: entities(:two))
    assert_equal awarded.id, analysis.representative_contract_id
  end

  test "upsert updates existing BenfordAnalysis on second run" do
    create_contracts(prices: Array.new(25) { |i| 9_000 + i }, prefix: "ba-upsert")

    Flags::Actions::BenfordLawAction.new.call
    first_chi2 = BenfordAnalysis.find_by!(entity: entities(:two)).chi_square

    Flags::Actions::BenfordLawAction.new.call
    second_chi2 = BenfordAnalysis.find_by!(entity: entities(:two)).chi_square

    assert_equal first_chi2, second_chi2
    assert_equal 1, BenfordAnalysis.where(entity: entities(:two)).count
  end
end
