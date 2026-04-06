require "test_helper"

class FlagTest < ActiveSupport::TestCase
  test "valid flag" do
    flag = Flag.new(
      contract: contracts(:one),
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      score: 40,
      details: { "rule" => "A2/A3" },
      fired_at: Time.current
    )

    assert flag.valid?
  end

  test "invalid without contract" do
    flag = Flag.new(
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      score: 40,
      fired_at: Time.current
    )

    assert_not flag.valid?
  end

  test "invalid without flag_type" do
    flag = Flag.new(
      contract: contracts(:one),
      severity: "high",
      score: 40,
      fired_at: Time.current
    )

    assert_not flag.valid?
  end

  test "invalid without severity" do
    flag = Flag.new(
      contract: contracts(:one),
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: nil,
      score: 40,
      fired_at: Time.current
    )

    assert_not flag.valid?
  end

  test "invalid without score" do
    flag = Flag.new(
      contract: contracts(:one),
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      fired_at: Time.current
    )

    assert_not flag.valid?
  end

  test "invalid without fired_at" do
    flag = Flag.new(
      contract: contracts(:one),
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      score: 40
    )

    assert_not flag.valid?
  end

  test "flag_type must be unique per contract" do
    attrs = {
      contract: contracts(:one),
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      score: 40,
      fired_at: Time.current
    }

    Flag.create!(attrs)
    duplicate = Flag.new(attrs)

    assert_not duplicate.valid?
  end

  test "same flag_type allowed for different contracts" do
    Flag.create!(
      contract: contracts(:one),
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      score: 40,
      fired_at: Time.current
    )

    other = Flag.new(
      contract: contracts(:two),
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      score: 40,
      fired_at: Time.current
    )

    assert other.valid?
  end

  # --- max_severity_sql ---

  test "max_severity_sql returns a non-empty SQL CASE string" do
    sql = Flag.max_severity_sql
    assert_kind_of String, sql
    assert sql.present?
    assert_match(/CASE/i, sql)
  end

  test "max_severity_sql picks the highest severity across mixed rows" do
    Flag.create!(contract: contracts(:one), flag_type: "Z9_MAX_SEV_TEST",
                 severity: "low",  score: 5,  fired_at: Time.current)
    Flag.create!(contract: contracts(:two), flag_type: "Z9_MAX_SEV_TEST",
                 severity: "high", score: 40, fired_at: Time.current)

    result = Flag.where(flag_type: "Z9_MAX_SEV_TEST")
                 .select("#{Flag.max_severity_sql} AS max_severity")
                 .first

    assert_equal "high", result.max_severity
  end

  test "max_severity_sql returns low when all flags are low severity" do
    Flag.create!(contract: contracts(:one), flag_type: "Z9_ONLY_LOW_TEST",
                 severity: "low", score: 5, fired_at: Time.current)

    result = Flag.where(flag_type: "Z9_ONLY_LOW_TEST")
                 .select("#{Flag.max_severity_sql} AS max_severity")
                 .first

    assert_equal "low", result.max_severity
  end

  test "max_severity_sql returns critical when a critical flag is present" do
    Flag.create!(contract: contracts(:one), flag_type: "Z9_CRITICAL_TEST",
                 severity: "medium",   score: 20, fired_at: Time.current)
    Flag.create!(contract: contracts(:two), flag_type: "Z9_CRITICAL_TEST",
                 severity: "critical", score: 80, fired_at: Time.current)

    result = Flag.where(flag_type: "Z9_CRITICAL_TEST")
                 .select("#{Flag.max_severity_sql} AS max_severity")
                 .first

    assert_equal "critical", result.max_severity
  end
end
