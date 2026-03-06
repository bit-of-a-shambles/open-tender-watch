require "test_helper"

class Flags::Actions::DateSequenceAnomalyActionTest < ActiveSupport::TestCase
  def create_contract(external_id:, publication_date:, celebration_date:)
    Contract.create!(
      external_id: external_id,
      country_code: "PT",
      object: "Contrato #{external_id}",
      procedure_type: "Ajuste Direto",
      base_price: 1000,
      publication_date: publication_date,
      celebration_date: celebration_date,
      contracting_entity: entities(:one),
      data_source: data_sources(:portal_base)
    )
  end

  test "creates a flag when celebration date is more than 10 days before publication date" do
    # 16-day gap (2024-12-25 → 2025-01-10) — well above the MIN_PUBLICATION_DELAY_DAYS threshold.
    anomalous = create_contract(
      external_id: "rule-a2-1",
      publication_date: Date.new(2025, 1, 10),
      celebration_date: Date.new(2024, 12, 25)
    )
    create_contract(
      external_id: "rule-a2-2",
      publication_date: Date.new(2025, 1, 10),
      celebration_date: Date.new(2025, 1, 11)
    )

    assert_difference "Flag.count", 1 do
      result = Flags::Actions::DateSequenceAnomalyAction.new.call
      assert_equal 1, result
    end

    flag = Flag.find_by!(contract_id: anomalous.id, flag_type: "A2_PUBLICATION_AFTER_CELEBRATION")
    assert_equal "high", flag.severity
    assert_equal 40, flag.score
    assert_equal "2025-01-10", flag.details["publication_date"]
    assert_equal "2024-12-25", flag.details["celebration_date"]
    assert_equal 16, flag.details["gap_days"]
    assert_match(/A2\/A3/, flag.details["rule"])
    assert_match(/16 days/, flag.details["rule"])
  end

  test "is idempotent for the same anomalous contract" do
    # 16-day gap (2025-01-25 → 2025-02-10) — above the threshold.
    create_contract(
      external_id: "rule-a2-idempotent",
      publication_date: Date.new(2025, 2, 10),
      celebration_date: Date.new(2025, 1, 25)
    )

    action = Flags::Actions::DateSequenceAnomalyAction.new
    assert_equal 1, action.call
    assert_no_difference "Flag.count" do
      assert_equal 1, action.call
    end
  end

  test "removes stale flags when contract no longer matches the anomaly" do
    # 14-day gap (2025-03-06 → 2025-03-20) — above the threshold.
    contract = create_contract(
      external_id: "rule-a2-stale",
      publication_date: Date.new(2025, 3, 20),
      celebration_date: Date.new(2025, 3, 6)
    )

    action = Flags::Actions::DateSequenceAnomalyAction.new
    action.call
    assert_equal 1, Flag.where(contract_id: contract.id).count

    contract.update!(celebration_date: Date.new(2025, 3, 21))

    assert_equal 0, action.call
    assert_equal 0, Flag.where(contract_id: contract.id).count
  end

  test "removes stale flags when non matching contracts exist and anomalies still exist" do
    # 21-day gap (2025-03-25 → 2025-04-15) — above the threshold.
    anomalous = create_contract(
      external_id: "rule-a2-kept",
      publication_date: Date.new(2025, 4, 15),
      celebration_date: Date.new(2025, 3, 25)
    )
    normal = create_contract(
      external_id: "rule-a2-cleared",
      publication_date: Date.new(2025, 4, 10),
      celebration_date: Date.new(2025, 4, 11)
    )
    Flag.create!(
      contract: normal,
      flag_type: "A2_PUBLICATION_AFTER_CELEBRATION",
      severity: "high",
      score: 40,
      fired_at: 2.days.ago
    )

    result = Flags::Actions::DateSequenceAnomalyAction.new.call
    assert_equal 1, result

    assert Flag.exists?(contract_id: anomalous.id, flag_type: "A2_PUBLICATION_AFTER_CELEBRATION")
    assert_not Flag.exists?(contract_id: normal.id, flag_type: "A2_PUBLICATION_AFTER_CELEBRATION")
  end

  test "does not fire when celebration_date equals publication_date (same day)" do
    create_contract(
      external_id: "rule-a2-same-day",
      publication_date: Date.new(2025, 6, 1),
      celebration_date: Date.new(2025, 6, 1)
    )

    assert_no_difference "Flag.count" do
      result = Flags::Actions::DateSequenceAnomalyAction.new.call
      assert_equal 0, result
    end
  end

  test "does not fire when celebration_date is after publication_date (normal order)" do
    create_contract(
      external_id: "rule-a2-normal",
      publication_date: Date.new(2025, 6, 1),
      celebration_date: Date.new(2025, 6, 5)
    )

    assert_no_difference "Flag.count" do
      result = Flags::Actions::DateSequenceAnomalyAction.new.call
      assert_equal 0, result
    end
  end

  test "does not fire when publication_date is nil" do
    create_contract(
      external_id: "rule-a2-nil-pub",
      publication_date: nil,
      celebration_date: Date.new(2025, 6, 1)
    )

    assert_no_difference "Flag.count" do
      result = Flags::Actions::DateSequenceAnomalyAction.new.call
      assert_equal 0, result
    end
  end

  test "does not fire when celebration_date is nil" do
    create_contract(
      external_id: "rule-a2-nil-cel",
      publication_date: Date.new(2025, 6, 1),
      celebration_date: nil
    )

    assert_no_difference "Flag.count" do
      result = Flags::Actions::DateSequenceAnomalyAction.new.call
      assert_equal 0, result
    end
  end

  test "does not fire when gap is only 1 day (below MIN_PUBLICATION_DELAY_DAYS threshold)" do
    # Portuguese practice: signing first, then publishing within a few days is normal.
    # A 1-day gap must NOT trigger A2.
    create_contract(
      external_id: "rule-a2-one-day",
      publication_date: Date.new(2026, 2, 28),
      celebration_date: Date.new(2026, 2, 27)
    )

    assert_no_difference "Flag.count" do
      result = Flags::Actions::DateSequenceAnomalyAction.new.call
      assert_equal 0, result
    end
  end

  # ---------------------------------------------------------------------------
  # Gap-threshold boundary tests (MIN_PUBLICATION_DELAY_DAYS = 10)
  # ---------------------------------------------------------------------------
  #
  # In Portugal the normal sequence is: authority signs first, then publishes to
  # BASE within a few working days. The MIN_PUBLICATION_DELAY_DAYS constant (10)
  # absorbs this normal administrative delay. Only longer gaps — indicative of
  # retroactive documentation — are flagged as A2.
  #
  # Context: before this threshold was introduced, A2 fired on ~85% of all
  # contracts. The threshold reduces noise and makes A2 meaningful.

  test "does not fire when gap is exactly 10 days (at the threshold boundary)" do
    create_contract(
      external_id:      "a2-gap-10d",
      publication_date: Date.new(2025, 2, 11),
      celebration_date: Date.new(2025, 2, 1)  # exactly 10 days prior
    )

    assert_no_difference "Flag.count" do
      Flags::Actions::DateSequenceAnomalyAction.new.call
    end
  end

  test "fires when gap is exactly 11 days (one above the threshold)" do
    anomalous = create_contract(
      external_id:      "a2-gap-11d",
      publication_date: Date.new(2025, 2, 12),
      celebration_date: Date.new(2025, 2, 1)  # exactly 11 days prior
    )

    assert_difference "Flag.count", 1 do
      Flags::Actions::DateSequenceAnomalyAction.new.call
    end

    assert Flag.exists?(contract_id: anomalous.id, flag_type: "A2_PUBLICATION_AFTER_CELEBRATION")
  end

  test "fires for a 30-day gap" do
    # 30-day gap is above the threshold and correctly triggers A2.
    anomalous = create_contract(
      external_id:      "a2-gap-30d",
      publication_date: Date.new(2025, 2, 1),
      celebration_date: Date.new(2025, 1, 2)  # exactly 30 days prior
    )

    assert_difference "Flag.count", 1 do
      Flags::Actions::DateSequenceAnomalyAction.new.call
    end

    assert Flag.exists?(contract_id: anomalous.id, flag_type: "A2_PUBLICATION_AFTER_CELEBRATION")
  end

  test "fires for a 90-day gap (clearly late publication — should always flag)" do
    # A 90-day delay between contract signing and BASE publication is far outside
    # any legal tolerance and strongly indicates retroactive documentation.
    # This MUST fire regardless of any future minimum-gap threshold.
    anomalous = create_contract(
      external_id:      "a2-gap-90d",
      publication_date: Date.new(2025, 4, 1),
      celebration_date: Date.new(2025, 1, 1)  # 90 days prior
    )

    assert_difference "Flag.count", 1 do
      Flags::Actions::DateSequenceAnomalyAction.new.call
    end

    assert Flag.exists?(contract_id: anomalous.id, flag_type: "A2_PUBLICATION_AFTER_CELEBRATION"),
           "A 90-day gap must always trigger A2 regardless of any future threshold"
  end

  test "fires for a 365-day gap (extreme late publication)" do
    anomalous = create_contract(
      external_id:      "a2-gap-365d",
      publication_date: Date.new(2025, 12, 31),
      celebration_date: Date.new(2025, 1, 1)  # 364 days prior
    )

    assert_difference "Flag.count", 1 do
      Flags::Actions::DateSequenceAnomalyAction.new.call
    end

    assert Flag.exists?(contract_id: anomalous.id, flag_type: "A2_PUBLICATION_AFTER_CELEBRATION")
  end
end
