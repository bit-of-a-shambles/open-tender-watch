require "test_helper"

class EntityTest < ActiveSupport::TestCase
  test "valid entity" do
    entity = Entity.new(name: "Test Entity", tax_identifier: "123456789", country_code: "PT")
    assert entity.valid?
  end

  test "invalid without name" do
    entity = Entity.new(tax_identifier: "123456789", country_code: "PT")
    assert_not entity.valid?
    assert entity.errors.added?(:name, :blank)
  end

  test "invalid without tax_identifier" do
    entity = Entity.new(name: "Test Entity", country_code: "PT")
    assert_not entity.valid?
  end

  test "invalid without country_code" do
    entity = Entity.new(name: "Test Entity", tax_identifier: "123456789")
    entity.country_code = ""
    assert_not entity.valid?
  end

  test "tax_identifier must be unique within country" do
    existing = entities(:one)
    duplicate = Entity.new(
      name:           "Other",
      tax_identifier: existing.tax_identifier,
      country_code:   existing.country_code
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors.details[:tax_identifier].map { |e| e[:error] }, :taken
  end

  test "same tax_identifier allowed in different countries" do
    existing = entities(:one)
    other_country = Entity.new(
      name:           "Spanish clone",
      tax_identifier: existing.tax_identifier,
      country_code:   "ES"
    )
    assert other_country.valid?
  end

  test "has many contracts_as_contracting_entity" do
    assert_respond_to entities(:one), :contracts_as_contracting_entity
  end

  test "has many contract_winners" do
    assert_respond_to entities(:one), :contract_winners
  end

  test "has many contract_bidders" do
    assert_respond_to entities(:one), :contract_bidders
  end

  test "has many contracts_won through contract_winners" do
    assert_respond_to entities(:one), :contracts_won
  end

  test "has many contracts_bid_on through contract_bidders" do
    assert_respond_to entities(:one), :contracts_bid_on
  end
end
