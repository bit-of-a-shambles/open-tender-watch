# frozen_string_literal: true

require "test_helper"

class PersonTest < ActiveSupport::TestCase
  test "valid person saves successfully" do
    person = Person.new(name: "Ana Ferreira", tax_identifier: "111222333", country_code: "PT")
    assert person.valid?
    assert person.save
  end

  test "invalid without name" do
    person = Person.new(country_code: "PT")
    assert_not person.valid?
    assert person.errors[:name].any?
  end

  test "invalid without country_code" do
    person = Person.new(name: "Ana Ferreira")
    person.country_code = nil
    assert_not person.valid?
  end

  test "tax identifier is unique within country when present" do
    Person.create!(name: "Ana Ferreira", tax_identifier: "111222333", country_code: "PT")

    duplicate = Person.new(name: "Outra Ana", tax_identifier: "111222333", country_code: "PT")
    assert_not duplicate.valid?
  end

  test "blank tax identifier may repeat" do
    Person.create!(name: "Ana Ferreira", country_code: "PT")

    duplicate = Person.new(name: "Ana Ferreira", country_code: "PT")
    assert duplicate.valid?
  end
end