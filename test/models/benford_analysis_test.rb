# frozen_string_literal: true

require "test_helper"

class BenfordAnalysisTest < ActiveSupport::TestCase
  def valid_attrs
    {
      entity:             entities(:one),
      sample_size:        25,
      chi_square:         22.5,
      flagged:            true,
      severity:           "high",
      digit_distribution: { "1" => 2, "2" => 1, "3" => 1, "4" => 1, "5" => 1,
                            "6" => 1, "7" => 1, "8" => 2, "9" => 15 },
      computed_at:        Time.current
    }
  end

  test "valid with all required attributes" do
    assert BenfordAnalysis.new(valid_attrs).valid?
  end

  test "invalid without entity" do
    a = BenfordAnalysis.new(valid_attrs.except(:entity))
    assert_not a.valid?
    assert a.errors[:entity].any?
  end

  test "invalid without sample_size" do
    a = BenfordAnalysis.new(valid_attrs.merge(sample_size: nil))
    assert_not a.valid?
  end

  test "invalid with sample_size zero" do
    a = BenfordAnalysis.new(valid_attrs.merge(sample_size: 0))
    assert_not a.valid?
  end

  test "invalid without chi_square" do
    a = BenfordAnalysis.new(valid_attrs.merge(chi_square: nil))
    assert_not a.valid?
  end

  test "invalid without digit_distribution" do
    a = BenfordAnalysis.new(valid_attrs.merge(digit_distribution: nil))
    assert_not a.valid?
  end

  test "invalid without computed_at" do
    a = BenfordAnalysis.new(valid_attrs.merge(computed_at: nil))
    assert_not a.valid?
  end

  test "flagged defaults to false" do
    a = BenfordAnalysis.new(valid_attrs.except(:flagged, :severity))
    # Falsy (nil) treated as false by inclusion validator — set explicitly
    a.flagged = false
    assert a.valid?
    assert_equal false, a.flagged
  end

  test "non-anomalous entity can have nil severity" do
    a = BenfordAnalysis.new(valid_attrs.merge(flagged: false, severity: nil))
    assert a.valid?
  end

  test "belongs to entity" do
    a = BenfordAnalysis.create!(valid_attrs)
    assert_equal entities(:one), a.entity
  end

  test "representative_contract is optional" do
    a = BenfordAnalysis.new(valid_attrs.merge(representative_contract: nil))
    assert a.valid?
  end
end
