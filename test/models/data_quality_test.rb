# frozen_string_literal: true

# Data Quality Invariants
#
# These tests codify structural guarantees surfaced by the production sense-check
# run on 2026-03-06. They run against the test fixtures (not live data) and serve
# three purposes:
#
#   1. Regression guards — ensure future schema/validation changes don't silently
#      break a constraint that production data depends on.
#   2. Living documentation — make explicit which edge cases (negative prices,
#      TED synthetic NIFs, large framework ceilings) the system must accept.
#   3. Flag-type contract — assert the flag-type strings used throughout the app
#      match what the flag actions actually produce.
#
require "test_helper"

class DataQualityTest < ActiveSupport::TestCase
  # ── Entity uniqueness ────────────────────────────────────────────────────────

  test "entity tax_identifier must be unique within the same country_code" do
    dup = Entity.new(
      name:           "Duplicate Entity",
      tax_identifier: entities(:one).tax_identifier,
      country_code:   entities(:one).country_code
    )
    assert_not dup.valid?,
               "Two entities must not share the same (tax_identifier, country_code)"
    assert_includes dup.errors.details[:tax_identifier].map { |e| e[:error] }, :taken
  end

  test "same tax_identifier is valid across different country_codes" do
    cross_border = Entity.new(
      name:           "Cross-border entity with same NIF pattern",
      tax_identifier: entities(:one).tax_identifier,
      country_code:   "EU"
    )
    assert cross_border.valid?,
           "tax_identifier uniqueness is scoped to country_code; foreign entities with the same NIF must be accepted"
  end

  test "TED synthetic NIF format (TED-<hex>) is a valid tax_identifier" do
    # When importing TED notices with no buyer NIF the adapter derives a
    # deterministic synthetic ID: "TED-#{MD5(name)[0,12]}".
    # The Entity model must not impose a numeric-only constraint on tax_identifier.
    ted = Entity.new(
      name:           "Unknown TED Supplier",
      tax_identifier: "TED-1a2b3c4d5e6f",
      country_code:   "EU",
      is_public_body: false
    )
    assert ted.valid?,
           "TED synthetic identifiers (TED-<hex>) must be accepted as tax_identifiers"
  end

  test "entity requires name and tax_identifier" do
    no_name = Entity.new(tax_identifier: "500000001", country_code: "PT")
    no_nif  = Entity.new(name: "Some Entity",          country_code: "PT")
    assert_not no_name.valid?,          "Entity without name must be invalid"
    assert_not no_nif.valid?,           "Entity without tax_identifier must be invalid"
  end

  # ── Contract structural integrity ────────────────────────────────────────────

  test "contract requires external_id and object" do
    no_id  = Contract.new(object: "has object", country_code: "PT",
                          contracting_entity: entities(:one))
    no_obj = Contract.new(external_id: "has-id", country_code: "PT",
                          contracting_entity: entities(:one))
    assert_not no_id.valid?,  "external_id is required"
    assert_not no_obj.valid?, "object is required"
  end

  test "contract external_id must be unique within country_code" do
    existing = contracts(:one)
    dup = Contract.new(
      external_id:        existing.external_id,
      country_code:       existing.country_code,
      object:             "Duplicate",
      contracting_entity: entities(:one)
    )
    assert_not dup.valid?, "duplicate (external_id, country_code) must be rejected"
    assert dup.errors.details[:external_id].any? { |e| e[:error] == :taken }
  end

  test "same external_id is valid in a different country_code" do
    existing = contracts(:one)
    other = Contract.new(
      external_id:        existing.external_id,
      country_code:       "EU",
      object:             "Cross-border notice",
      contracting_entity: entities(:one)
    )
    assert other.valid?,
           "external_id uniqueness is scoped to country_code"
  end

  # ── Price edge cases ──────────────────────────────────────────────────────────

  test "negative base_price is valid (concession contracts — private pays public)" do
    # Portuguese BASE records billboard licences, bar concessions, vehicle sales,
    # and parking franchises with negative prices because the private entity pays
    # the public authority.  The model must not reject them.
    concession = Contract.new(
      external_id:        "dq-conc-base",
      object:             "Concessão de bar e esplanada — Parque Municipal",
      country_code:       "PT",
      contracting_entity: entities(:one),
      base_price:         -54_000
    )
    assert concession.valid?,
           "Negative base_price must be accepted for concession/revenue contracts"
  end

  test "negative total_effective_price is valid (concession contracts)" do
    concession = Contract.new(
      external_id:           "dq-conc-eff",
      object:                "Concessão de parque de estacionamento",
      country_code:          "PT",
      contracting_entity:    entities(:one),
      base_price:            -50_000,
      total_effective_price: -48_500
    )
    assert concession.valid?,
           "Negative total_effective_price must be accepted for concession contracts"
  end

  test "very large base_price is valid (framework agreement ceilings)" do
    # Some Portuguese framework agreements have ceilings in the billions of EUR.
    # Example found in production: 13 call-offs each showing the full €10.575B
    # framework ceiling as base_price.  The model must not impose an upper cap —
    # outlier detection is handled by the A9 flag service.
    framework = Contract.new(
      external_id:        "dq-framework-ceiling",
      object:             "Acordo-quadro IT — Administração Pública",
      country_code:       "PT",
      contracting_entity: entities(:one),
      base_price:         10_575_800_000
    )
    assert framework.valid?,
           "base_price > EUR 1B must be accepted; framework agreements can have large ceilings"
  end

  test "nil base_price and nil total_effective_price are both accepted" do
    # Not all sources provide prices for all records (e.g. prior-information
    # notices, some TED notices).
    no_price = Contract.new(
      external_id:        "dq-no-price",
      object:             "Prior information notice",
      country_code:       "EU",
      contracting_entity: entities(:one),
      base_price:         nil,
      total_effective_price: nil
    )
    assert no_price.valid?, "Contracts without prices must be accepted"
  end

  # ── Fixture sanity ────────────────────────────────────────────────────────────

  test "fixture contracts have positive base prices" do
    # All standard fixtures should represent awarded contracts with positive
    # prices.  Use helpers that build negative-price contracts explicitly when
    # testing concession logic.
    [ contracts(:one), contracts(:two) ].each do |c|
      next unless c.base_price

      assert c.base_price > 0,
             "Fixture #{c.external_id} has non-positive base_price (#{c.base_price}); " \
             "use a separate helper if you need to test concession contracts"
    end
  end

  test "fixture contracts have publication_date not in the future" do
    # Sense-check confirmed 0 future-dated contracts in production — fixtures
    # must uphold the same guarantee.
    [ contracts(:one), contracts(:two) ].each do |c|
      next unless c.publication_date

      assert c.publication_date <= Date.today + 1,
             "Fixture #{c.external_id} has publication_date #{c.publication_date} in the future"
    end
  end

  test "fixture contract_winners have non-negative price_share" do
    # Sense-check confirmed no negative price_shares in production.
    [ contract_winners(:one), contract_winners(:two) ].each do |cw|
      next unless cw.price_share

      assert cw.price_share >= 0,
             "ContractWinner #{cw.id} has negative price_share (#{cw.price_share})"
    end
  end

  test "all fixture flags reference a known flag_type" do
    # Known flag types — update this list whenever a new flag action is added.
    known_types = %w[
      A1_REPEAT_DIRECT_AWARD
      A2_PUBLICATION_AFTER_CELEBRATION
      A5_THRESHOLD_SPLITTING
      A9_PRICE_ANOMALY
      A9_PRICE_REDUCTION
      B2_SUPPLIER_CONCENTRATION
      B5_BENFORD_DEVIATION
      C1_MISSING_WINNER_NIF
      C3_MISSING_MANDATORY_FIELDS
    ].freeze

    Flag.all.each do |flag|
      assert_includes known_types, flag.flag_type,
                      "Flag ##{flag.id} has unrecognised flag_type '#{flag.flag_type}'; " \
                      "add it to the known_types list in data_quality_test.rb"
    end
  end

  test "flag action constants are all in the known flag_type registry" do
    # Verifies that every FLAG_TYPE constant defined in a flag action class is
    # represented in the sense-check registry above.  Add to known_types here
    # whenever a new flag action is added.
    known_types = %w[
      A1_REPEAT_DIRECT_AWARD
      A2_PUBLICATION_AFTER_CELEBRATION
      A5_THRESHOLD_SPLITTING
      A9_PRICE_ANOMALY
      A9_PRICE_REDUCTION
      B2_SUPPLIER_CONCENTRATION
      B5_BENFORD_DEVIATION
      C1_MISSING_WINNER_NIF
      C3_MISSING_MANDATORY_FIELDS
    ].freeze

    action_classes = [
      Flags::Actions::DateSequenceAnomalyAction,
      Flags::Actions::PriceAnomalyAction,
      Flags::Actions::ThresholdSplittingAction,
      Flags::Actions::RepeatDirectAwardAction,
      Flags::Actions::SupplierConcentrationAction,
      Flags::Actions::MissingMandatoryFieldsAction,
      Flags::Actions::MissingWinnerNifAction,
      Flags::Actions::BenfordLawAction
    ]

    action_classes.each do |klass|
      klass.constants.select { |c| c.to_s.start_with?("FLAG") }.each do |const|
        type = klass.const_get(const)
        assert_includes known_types, type,
                        "#{klass}::#{const} = '#{type}' is not in the known_types registry; " \
                        "add it to data_quality_test.rb"
      end
    end
  end
end
