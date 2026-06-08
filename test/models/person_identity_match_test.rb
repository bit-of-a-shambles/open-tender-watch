# frozen_string_literal: true

require "test_helper"

class PersonIdentityMatchTest < ActiveSupport::TestCase
  setup do
    @left = Person.create!(name: "Ana Matos", country_code: "PT")
    @right = Person.create!(name: "Ana Matos", country_code: "PT")
  end

  test "valid match saves successfully" do
    match = PersonIdentityMatch.new(
      left_person: @left,
      right_person: @right,
      match_type: "exact_name_context",
      confidence: "high",
      score: 80
    )

    assert match.valid?
    assert match.save
  end

  test "validates controlled fields" do
    match = PersonIdentityMatch.new(
      left_person: @left,
      right_person: @right,
      match_type: "unsupported",
      confidence: "certain",
      review_status: "maybe",
      score: -1
    )

    assert_not match.valid?
    assert match.errors[:match_type].any?
    assert match.errors[:confidence].any?
    assert match.errors[:review_status].any?
    assert match.errors[:score].any?
  end

  test "actionable scope only includes high confidence non-rejected matches" do
    high = PersonIdentityMatch.create!(left_person: @left, right_person: @right, match_type: "same_nif", confidence: "high", score: 100)
    low = PersonIdentityMatch.create!(left_person: @left, right_person: @right, match_type: "exact_name_only", confidence: "low", score: 20)
    rejected = PersonIdentityMatch.create!(left_person: @left, right_person: @right, match_type: "exact_name_context", confidence: "high", score: 80, review_status: "rejected")

    assert_includes PersonIdentityMatch.actionable, high
    assert_not_includes PersonIdentityMatch.actionable, low
    assert_not_includes PersonIdentityMatch.actionable, rejected
  end
end
