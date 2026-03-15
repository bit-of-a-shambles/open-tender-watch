# frozen_string_literal: true

require "test_helper"

class CompanyDirectorTest < ActiveSupport::TestCase
  test "valid director saves successfully" do
    director = CompanyDirector.new(
      entity: entities(:two),
      name: "Ana Ferreira",
      role: "Diretora",
      tax_identifier: "555000111",
      country_code: "PT"
    )
    assert director.valid?
    assert director.save
  end

  test "invalid without name" do
    director = CompanyDirector.new(entity: entities(:two), country_code: "PT")
    assert_not director.valid?
    assert_includes director.errors[:name], "can't be blank"
  end

  test "country_code defaults to PT when omitted" do
    director = CompanyDirector.new(entity: entities(:two), name: "Test")
    # column default is "PT" — model is always valid when only name provided
    assert director.valid?
    assert_equal "PT", director.country_code
  end

  test "fixtures load correctly" do
    assert_equal entities(:two), company_directors(:one).entity
    assert_equal "João Silva", company_directors(:one).name
    assert_equal "Gerente", company_directors(:one).role
    assert_equal "123456789", company_directors(:one).tax_identifier
    assert_equal "PT", company_directors(:one).country_code
  end

  test "entity has_many company_directors" do
    assert_includes entities(:two).company_directors, company_directors(:one)
    assert_includes entities(:two).company_directors, company_directors(:two)
  end

  test "destroying entity destroys directors" do
    entity = Entity.create!(name: "Temp", tax_identifier: "700000001", country_code: "PT")
    CompanyDirector.create!(entity: entity, name: "Temp Dir", country_code: "PT")
    assert_difference "CompanyDirector.count", -1 do
      entity.destroy
    end
  end
end
