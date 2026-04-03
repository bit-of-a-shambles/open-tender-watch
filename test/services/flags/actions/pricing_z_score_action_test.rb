# frozen_string_literal: true

require "test_helper"

class Flags::Actions::PricingZScoreActionTest < ActiveSupport::TestCase
  FLAG_HIGH = Flags::Actions::PricingZScoreAction::FLAG_HIGH
  FLAG_LOW  = Flags::Actions::PricingZScoreAction::FLAG_LOW
  Z_MED     = Flags::Actions::PricingZScoreAction::Z_MED
  Z_HIGH    = Flags::Actions::PricingZScoreAction::Z_HIGH
  MIN_SAMPLE = Flags::Actions::PricingZScoreAction::MIN_SAMPLE

  # Helper: create a contract with an explicit base_price in CPV div "30", year 2024.
  def make_contract(external_id:, base_price:, cpv_code: "30192000", pub_year: 2024)
    Contract.create!(
      external_id:        external_id,
      country_code:       "PT",
      object:             "Test #{external_id}",
      procedure_type:     "Ajuste Direto",
      cpv_code:           cpv_code,
      publication_date:   Date.new(pub_year, 6, 1),
      base_price:         base_price,
      contracting_entity: entities(:one),
      data_source:        data_sources(:portal_base)
    )
  end

  # Build a peer group (cpv_div=30, year=2024) with 14 contracts:
  # 13 equal peers at 10_000 + 1 outlier at any different value.
  # With n equal peers, the outlier's z-score = sqrt(n) regardless of its
  # value. sqrt(13) ≈ 3.61 >= Z_HIGH (3.5) → high severity.
  def setup_high_outlier_group
    13.times do |i|
      make_contract(external_id: "b3-peer-#{i}", base_price: 10_000)
    end
    make_contract(external_id: "b3-outlier-high", base_price: 500_000)
  end

  # Build a peer group with one low outlier (suspiciously cheap).
  def setup_low_outlier_group(cpv: "30999999", year: 2023)
    (MIN_SAMPLE - 1).times do |i|
      make_contract(external_id: "b3-low-peer-#{i}", base_price: 50_000,
                    cpv_code: cpv, pub_year: year)
    end
    # one contract at 1/20 the peer mean
    make_contract(external_id: "b3-outlier-low", base_price: 500,
                  cpv_code: cpv, pub_year: year)
  end

  test "flags high-price outlier as B3_PRICE_HIGH" do
    setup_high_outlier_group

    assert_difference "Flag.count", 1 do
      Flags::Actions::PricingZScoreAction.new.call
    end

    flag = Flag.find_by(flag_type: FLAG_HIGH)
    assert_not_nil flag
    z = flag.details["z_score"].to_f
    assert_operator z, :>, Z_MED
    assert_equal "high", flag.severity
    assert_equal Flags::Actions::PricingZScoreAction::SCORE_HIGH, flag.score
  end

  test "flags low-price outlier as B3_PRICE_LOW" do
    setup_low_outlier_group

    assert_difference "Flag.count", 1 do
      Flags::Actions::PricingZScoreAction.new.call
    end

    flag = Flag.find_by(flag_type: FLAG_LOW)
    assert_not_nil flag
    z = flag.details["z_score"].to_f
    assert_operator z, :<, -Z_MED
  end

  test "does not flag when all prices are within normal range" do
    # Tight cluster — no outlier beyond Z_MED
    MIN_SAMPLE.times do |i|
      make_contract(external_id: "b3-normal-#{i}", base_price: 10_000 + i * 10)
    end

    assert_no_difference "Flag.count" do
      Flags::Actions::PricingZScoreAction.new.call
    end
  end

  test "skips peer groups with fewer than MIN_SAMPLE contracts" do
    # Only 5 contracts in this CPV div — below MIN_SAMPLE → no flag
    5.times do |i|
      make_contract(external_id: "b3-small-#{i}", base_price: i == 4 ? 999_999 : 10_000,
                    cpv_code: "98000000")
    end

    assert_no_difference "Flag.count" do
      Flags::Actions::PricingZScoreAction.new.call
    end
  end

  test "is idempotent — calling twice does not duplicate flags" do
    setup_high_outlier_group
    Flags::Actions::PricingZScoreAction.new.call

    assert_no_difference "Flag.count" do
      Flags::Actions::PricingZScoreAction.new.call
    end
  end

  test "details hash contains required keys" do
    setup_high_outlier_group
    Flags::Actions::PricingZScoreAction.new.call

    flag = Flag.find_by(flag_type: FLAG_HIGH)
    assert_not_nil flag
    %w[z_score base_price peer_mean peer_stddev peer_n cpv_div pub_year rule].each do |key|
      assert flag.details.key?(key), "Expected details to contain '#{key}'"
    end
  end

  test "removes stale flags when outlier contract is updated to a normal price" do
    setup_high_outlier_group
    Flags::Actions::PricingZScoreAction.new.call

    assert_equal 1, Flag.where(flag_type: FLAG_HIGH).count

    # Normalize the outlier to match peer price exactly.
    # With all 14 values == 10_000, stddev = 0 and the HAVING clause
    # drops the peer group → no contracts from this group are flagged.
    Contract.find_by(external_id: "b3-outlier-high").update!(base_price: 10_000)

    # Re-run — action does delete_all then rebuild, so stale flag disappears
    Flags::Actions::PricingZScoreAction.new.call

    assert_equal 0, Flag.where(flag_type: FLAG_HIGH).count
  end
end
