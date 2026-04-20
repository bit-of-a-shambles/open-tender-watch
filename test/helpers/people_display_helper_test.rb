# frozen_string_literal: true

require "test_helper"

class PeopleDisplayHelperTest < ActionView::TestCase
  include PeopleDisplayHelper

  setup do
    @entity = entities(:two)
    @person_joao = people(:joao)
    @person_maria = people(:maria)
    @role_joao = EntityPersonRole.create!(
      entity: @entity, person: @person_joao,
      role_type: "director", role_label: "Gerente",
      source_name: "Registo Comercial", active: true, start_date: Date.new(2020, 1, 15)
    )
    @role_maria = EntityPersonRole.create!(
      entity: @entity, person: @person_maria,
      role_type: "partner_shareholder", role_label: "Sócia",
      source_name: "Registo Comercial", active: true, start_date: Date.new(2018, 6, 1)
    )
  end

  # Stub journalist_access? for testing
  def journalist_access?
    @_journalist_access || false
  end

  test "display_person_name returns pseudonym for public" do
    @_journalist_access = false
    name = display_person_name(@role_joao)
    assert_match(/\[P-[0-9a-f]{4}\]/, name)
    assert_not_includes name, "João"
  end

  test "display_person_name returns full name for journalist" do
    @_journalist_access = true
    assert_equal "João Manuel da Silva", display_person_name(@role_joao)
  end

  test "display_person_nif returns nil for public" do
    @_journalist_access = false
    assert_nil display_person_nif(@role_joao)
  end

  test "display_person_nif returns NIF for journalist" do
    @_journalist_access = true
    assert_equal "123456789", display_person_nif(@role_joao)
  end

  test "pseudonym is deterministic for same person" do
    @_journalist_access = false
    name1 = display_person_name(@role_joao)
    name2 = display_person_name(@role_joao)
    assert_equal name1, name2
  end

  test "pseudonym differs for different people" do
    @_journalist_access = false
    name_joao = display_person_name(@role_joao)
    name_maria = display_person_name(@role_maria)
    assert_not_equal name_joao, name_maria
  end

  test "pseudonym shows initials" do
    @_journalist_access = false
    name = display_person_name(@role_joao)
    # "João Manuel da Silva" → initials should be "J.M" (skipping "da" which is 2 chars)
    assert_match(/^[A-Z]\.[A-Z]\./, name)
  end
end
