require "test_helper"

class Flags::Actions::RepeatDirectAwardActionTest < ActiveSupport::TestCase
  def create_supplier
    Entity.create!(
      name: "Fornecedor Teste Lda",
      tax_identifier: "509#{rand(100_000..999_999)}",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
  end

  def create_direct_award(external_id:, authority:, supplier:, publication_date:, base_price: 5_000, cpv_code: nil)
    contract = Contract.create!(
      external_id: external_id,
      country_code: "PT",
      object: "Contrato #{external_id}",
      procedure_type: "Ajuste Direto",
      base_price: base_price,
      cpv_code: cpv_code,
      publication_date: publication_date,
      contracting_entity: authority,
      data_source: data_sources(:portal_base)
    )
    ContractWinner.create!(contract: contract, entity: supplier)
    contract
  end

  # In-window year: within the current-year-2 window (today is 2026-04-06 → window from 2024-01-01)
  IN_WINDOW_YEAR  = Date.current.year - 1

  test "flags contracts when cumulative services price reaches the €20k threshold" do
    authority = entities(:one)
    supplier  = create_supplier

    # 3 × €8k = €24k ≥ €20k → should flag
    c1 = create_direct_award(external_id: "a1-svc-1", authority: authority, supplier: supplier, publication_date: Date.new(IN_WINDOW_YEAR, 1, 1), base_price: 8_000)
    c2 = create_direct_award(external_id: "a1-svc-2", authority: authority, supplier: supplier, publication_date: Date.new(IN_WINDOW_YEAR, 6, 1), base_price: 8_000)
    c3 = create_direct_award(external_id: "a1-svc-3", authority: authority, supplier: supplier, publication_date: Date.new(IN_WINDOW_YEAR, 12, 1), base_price: 8_000)

    assert_difference "Flag.count", 3 do
      result = Flags::Actions::RepeatDirectAwardAction.new.call
      assert_equal 3, result
    end

    [ c1, c2, c3 ].each do |contract|
      flag = Flag.find_by!(contract_id: contract.id, flag_type: "A1_REPEAT_DIRECT_AWARD")
      assert_equal "high", flag.severity
      assert_equal 3, flag.details["award_count"]
      assert_in_delta 24_000.0, flag.details["total_price"], 0.01
    end
  end

  test "flags contracts when cumulative works price reaches the €30k threshold" do
    authority = entities(:one)
    supplier  = create_supplier

    # 2 × €16k = €32k ≥ €30k works threshold → should flag
    c1 = create_direct_award(external_id: "a1-wrk-1", authority: authority, supplier: supplier, publication_date: Date.new(IN_WINDOW_YEAR, 1, 1), base_price: 16_000, cpv_code: "45210000")
    c2 = create_direct_award(external_id: "a1-wrk-2", authority: authority, supplier: supplier, publication_date: Date.new(IN_WINDOW_YEAR, 6, 1), base_price: 16_000, cpv_code: "45210000")

    assert_difference "Flag.count", 2 do
      Flags::Actions::RepeatDirectAwardAction.new.call
    end

    [ c1, c2 ].each do |contract|
      flag = Flag.find_by!(contract_id: contract.id, flag_type: "A1_REPEAT_DIRECT_AWARD")
      assert_in_delta 32_000.0, flag.details["works_price"], 0.01
    end
  end

  test "does not flag when cumulative price is below threshold even with 3 awards" do
    authority = entities(:one)
    supplier  = create_supplier

    # 3 × €5k = €15k < €20k → no flag
    create_direct_award(external_id: "a1-cheap-1", authority: authority, supplier: supplier, publication_date: Date.new(IN_WINDOW_YEAR, 1, 1), base_price: 5_000)
    create_direct_award(external_id: "a1-cheap-2", authority: authority, supplier: supplier, publication_date: Date.new(IN_WINDOW_YEAR, 6, 1), base_price: 5_000)
    create_direct_award(external_id: "a1-cheap-3", authority: authority, supplier: supplier, publication_date: Date.new(IN_WINDOW_YEAR, 12, 1), base_price: 5_000)

    assert_no_difference "Flag.count" do
      result = Flags::Actions::RepeatDirectAwardAction.new.call
      assert_equal 0, result
    end
  end

  test "does not fire when there is only one direct award in the window" do
    authority = entities(:one)
    supplier  = create_supplier

    create_direct_award(external_id: "a1-one-1", authority: authority, supplier: supplier, publication_date: Date.new(IN_WINDOW_YEAR, 1, 1), base_price: 25_000)

    assert_no_difference "Flag.count" do
      Flags::Actions::RepeatDirectAwardAction.new.call
    end
  end

  test "does not count awards outside the economic year window" do
    authority = entities(:one)
    supplier  = create_supplier

    # Two awards well outside the window + one inside → only 1 in-window → no flag
    create_direct_award(external_id: "a1-old-1", authority: authority, supplier: supplier, publication_date: Date.new(2018, 1, 1), base_price: 15_000)
    create_direct_award(external_id: "a1-old-2", authority: authority, supplier: supplier, publication_date: Date.new(2019, 6, 1), base_price: 15_000)
    create_direct_award(external_id: "a1-old-3", authority: authority, supplier: supplier, publication_date: Date.new(IN_WINDOW_YEAR, 3, 1), base_price: 15_000)

    assert_no_difference "Flag.count" do
      Flags::Actions::RepeatDirectAwardAction.new.call
    end
  end

  test "does not fire for non-direct-award procedure types" do
    authority = entities(:one)
    supplier  = create_supplier

    3.times do |i|
      contract = Contract.create!(
        external_id: "a1-tender-#{i}",
        country_code: "PT",
        object: "Concurso #{i}",
        procedure_type: "Concurso público",
        base_price: 10_000,
        publication_date: Date.new(IN_WINDOW_YEAR, i + 1, 1),
        contracting_entity: authority,
        data_source: data_sources(:portal_base)
      )
      ContractWinner.create!(contract: contract, entity: supplier)
    end

    assert_no_difference "Flag.count" do
      Flags::Actions::RepeatDirectAwardAction.new.call
    end
  end

  test "does not fire when contracts have no publication_date" do
    authority = entities(:one)
    supplier  = create_supplier

    3.times do |i|
      contract = Contract.create!(
        external_id: "a1-nodate-#{i}",
        country_code: "PT",
        object: "Sem data #{i}",
        procedure_type: "Ajuste Direto",
        base_price: 10_000,
        publication_date: nil,
        contracting_entity: authority,
        data_source: data_sources(:portal_base)
      )
      ContractWinner.create!(contract: contract, entity: supplier)
    end

    assert_no_difference "Flag.count" do
      Flags::Actions::RepeatDirectAwardAction.new.call
    end
  end

  test "separate authority+supplier pairs are evaluated independently" do
    authority  = entities(:one)
    supplier_a = create_supplier
    supplier_b = create_supplier

    # Supplier A: 2 awards at €7k each = €14k < €20k → no flag
    create_direct_award(external_id: "a1-sep-a1", authority: authority, supplier: supplier_a, publication_date: Date.new(IN_WINDOW_YEAR, 1, 1), base_price: 7_000)
    create_direct_award(external_id: "a1-sep-a2", authority: authority, supplier: supplier_a, publication_date: Date.new(IN_WINDOW_YEAR, 6, 1), base_price: 7_000)

    # Supplier B: 3 awards at €8k each = €24k ≥ €20k → flag
    b1 = create_direct_award(external_id: "a1-sep-b1", authority: authority, supplier: supplier_b, publication_date: Date.new(IN_WINDOW_YEAR, 1, 1), base_price: 8_000)
    b2 = create_direct_award(external_id: "a1-sep-b2", authority: authority, supplier: supplier_b, publication_date: Date.new(IN_WINDOW_YEAR, 6, 1), base_price: 8_000)
    b3 = create_direct_award(external_id: "a1-sep-b3", authority: authority, supplier: supplier_b, publication_date: Date.new(IN_WINDOW_YEAR, 9, 1), base_price: 8_000)

    assert_difference "Flag.count", 3 do
      result = Flags::Actions::RepeatDirectAwardAction.new.call
      assert_equal 3, result
    end

    [ b1, b2, b3 ].each do |c|
      assert Flag.exists?(contract_id: c.id, flag_type: "A1_REPEAT_DIRECT_AWARD")
    end
  end

  test "is idempotent" do
    authority = entities(:one)
    supplier  = create_supplier

    3.times do |i|
      create_direct_award(external_id: "a1-idem-#{i}", authority: authority, supplier: supplier, publication_date: Date.new(IN_WINDOW_YEAR, i + 1, 1), base_price: 8_000)
    end

    action = Flags::Actions::RepeatDirectAwardAction.new
    assert_equal 3, action.call
    assert_no_difference "Flag.count" do
      assert_equal 3, action.call
    end
  end

  test "removes stale flags when cumulative price drops below threshold" do
    authority = entities(:one)
    supplier  = create_supplier

    c1 = create_direct_award(external_id: "a1-stale-1", authority: authority, supplier: supplier, publication_date: Date.new(IN_WINDOW_YEAR, 1, 1), base_price: 8_000)
    c2 = create_direct_award(external_id: "a1-stale-2", authority: authority, supplier: supplier, publication_date: Date.new(IN_WINDOW_YEAR, 4, 1), base_price: 8_000)
    c3 = create_direct_award(external_id: "a1-stale-3", authority: authority, supplier: supplier, publication_date: Date.new(IN_WINDOW_YEAR, 8, 1), base_price: 8_000)

    action = Flags::Actions::RepeatDirectAwardAction.new
    assert_equal 3, action.call

    # Move c3 outside the economic window so pattern no longer qualifies
    c3.update!(publication_date: Date.new(2010, 1, 1))

    assert_equal 0, action.call
    assert_equal 0, Flag.where(flag_type: "A1_REPEAT_DIRECT_AWARD").count
  end
end
