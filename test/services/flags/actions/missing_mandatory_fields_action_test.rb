# frozen_string_literal: true

require "test_helper"

class Flags::Actions::MissingMandatoryFieldsActionTest < ActiveSupport::TestCase
  def create_contract(external_id:, **attrs)
    Contract.create!(
      external_id:        external_id,
      country_code:       "PT",
      object:             "Test #{external_id}",
      contracting_entity: entities(:one),
      data_source:        data_sources(:portal_base),
      **attrs
    )
  end

  test "flags a contract missing cpv_code" do
    contract = create_contract(
      external_id:    "c3-test-001",
      cpv_code:       nil,
      procedure_type: "Ajuste Direto",
      base_price:     1000
    )

    assert_difference "Flag.count", 1 do
      Flags::Actions::MissingMandatoryFieldsAction.new.call
    end

    flag = Flag.find_by(contract_id: contract.id,
                        flag_type: Flags::Actions::MissingMandatoryFieldsAction::FLAG_TYPE)
    assert_not_nil flag
    assert_includes flag.details["missing_fields"], "cpv_code"
    assert_equal Flags::Actions::MissingMandatoryFieldsAction::SCORE,    flag.score
    assert_equal Flags::Actions::MissingMandatoryFieldsAction::SEVERITY, flag.severity
  end

  test "flags a contract missing procedure_type" do
    contract = create_contract(
      external_id:    "c3-test-002",
      cpv_code:       "30192000",
      procedure_type: nil,
      base_price:     1000
    )

    Flags::Actions::MissingMandatoryFieldsAction.new.call

    flag = Flag.find_by(contract_id: contract.id,
                        flag_type: Flags::Actions::MissingMandatoryFieldsAction::FLAG_TYPE)
    assert_not_nil flag
    assert_includes flag.details["missing_fields"], "procedure_type"
  end

  test "flags a contract missing base_price" do
    contract = create_contract(
      external_id:    "c3-test-003",
      cpv_code:       "30192000",
      procedure_type: "Ajuste Direto",
      base_price:     nil
    )

    Flags::Actions::MissingMandatoryFieldsAction.new.call

    flag = Flag.find_by(contract_id: contract.id,
                        flag_type: Flags::Actions::MissingMandatoryFieldsAction::FLAG_TYPE)
    assert_not_nil flag
    assert_includes flag.details["missing_fields"], "base_price"
  end

  test "missing_fields list includes all absent fields" do
    contract = create_contract(
      external_id:    "c3-test-004",
      cpv_code:       nil,
      procedure_type: nil,
      base_price:     nil
    )

    Flags::Actions::MissingMandatoryFieldsAction.new.call

    flag = Flag.find_by(contract_id: contract.id,
                        flag_type: Flags::Actions::MissingMandatoryFieldsAction::FLAG_TYPE)
    assert_not_nil flag
    assert_equal %w[cpv_code procedure_type base_price], flag.details["missing_fields"]
  end

  test "is idempotent — calling twice does not duplicate flags" do
    create_contract(
      external_id:    "c3-test-005",
      cpv_code:       nil,
      procedure_type: "Ajuste Direto",
      base_price:     1000
    )

    Flags::Actions::MissingMandatoryFieldsAction.new.call

    assert_no_difference "Flag.count" do
      Flags::Actions::MissingMandatoryFieldsAction.new.call
    end
  end

  test "removes stale flags when the field is filled in" do
    contract = create_contract(
      external_id:    "c3-test-006",
      cpv_code:       nil,
      procedure_type: "Ajuste Direto",
      base_price:     1000
    )

    Flags::Actions::MissingMandatoryFieldsAction.new.call
    assert_equal 1, Flag.where(flag_type: Flags::Actions::MissingMandatoryFieldsAction::FLAG_TYPE,
                               contract_id: contract.id).count

    # Fill in the missing field
    contract.update!(cpv_code: "30192000")

    assert_difference "Flag.where(flag_type: Flags::Actions::MissingMandatoryFieldsAction::FLAG_TYPE).count", -1 do
      Flags::Actions::MissingMandatoryFieldsAction.new.call
    end
  end

  test "does not flag contracts with all mandatory fields present" do
    create_contract(
      external_id:    "c3-test-007",
      cpv_code:       "30192000",
      procedure_type: "Ajuste Direto",
      base_price:     5000
    )

    assert_no_difference "Flag.count" do
      Flags::Actions::MissingMandatoryFieldsAction.new.call
    end
  end
end
