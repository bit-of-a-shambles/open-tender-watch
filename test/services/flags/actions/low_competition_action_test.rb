# frozen_string_literal: true

require "test_helper"

class Flags::Actions::LowCompetitionActionTest < ActiveSupport::TestCase
  def create_contract(external_id:, bidder_count:, **attrs)
    Contract.create!(
      external_id: external_id,
      country_code: "PT",
      object: "Test #{external_id}",
      procedure_type: "Concurso público",
      base_price: 1000,
      bidder_count: bidder_count,
      contracting_entity: entities(:one),
      data_source: data_sources(:portal_base),
      **attrs
    )
  end

  test "creates a flag for contracts with one bidder" do
    contract = create_contract(external_id: "a6-001", bidder_count: 1)

    assert_difference "Flag.count", 1 do
      Flags::Actions::LowCompetitionAction.new.call
    end

    flag = Flag.find_by!(contract_id: contract.id, flag_type: Flags::Actions::LowCompetitionAction::FLAG_TYPE)
    assert_equal Flags::Actions::LowCompetitionAction::SCORE, flag.score
    assert_equal "a6_single_bidder", flag.details["rule"]
  end

  test "does not flag contracts with more than one bidder or missing bidder count" do
    create_contract(external_id: "a6-002", bidder_count: 2)
    create_contract(external_id: "a6-003", bidder_count: nil)

    assert_no_difference "Flag.count" do
      Flags::Actions::LowCompetitionAction.new.call
    end
  end

  test "removes stale flags when bidder_count is updated" do
    contract = create_contract(external_id: "a6-004", bidder_count: 1)
    action = Flags::Actions::LowCompetitionAction.new

    action.call
    assert Flag.exists?(contract_id: contract.id, flag_type: Flags::Actions::LowCompetitionAction::FLAG_TYPE)

    contract.update!(bidder_count: 3)

    assert_difference "Flag.count", -1 do
      action.call
    end
  end
end
