require "test_helper"

class PublicContracts::ImportServiceTest < ActiveSupport::TestCase
  def build_contract_attrs(overrides = {})
    {
      "external_id"   => "ext-#{SecureRandom.hex(4)}",
      "object"        => "Serviços de consultoria",
      "country_code"  => "PT",
      "contract_type" => "Aquisição de Serviços",
      "procedure_type" => "Ajuste Direto",
      "publication_date" => Date.new(2025, 1, 10),
      "celebration_date" => Date.new(2025, 1, 12),
      "base_price"    => 15000.0,
      "total_effective_price" => 14500.0,
      "cpv_code"      => "72224000",
      "location"      => "Lisboa",
      "contracting_entity" => {
        "tax_identifier" => "500000001",
        "name"           => "Câmara Municipal Teste",
        "is_public_body" => true
      },
      "winners" => [
        { "tax_identifier" => "509888001", "name" => "Empresa Vencedora Lda", "is_company" => true }
      ]
    }.merge(overrides)
  end

  def with_mocked_adapter(contracts)
    adapter = Minitest::Mock.new
    adapter.expect(:fetch_contracts, contracts)
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      yield ds, adapter
    end
    adapter.verify
  end

  # ── happy path ────────────────────────────────────────────────────────────

  test "call creates a contract from adapter data" do
    attrs = build_contract_attrs
    with_mocked_adapter([ attrs ]) do |ds, _|
      assert_difference "Contract.count", 1 do
        PublicContracts::ImportService.new(ds).call
      end
    end
  end

  test "call creates the contracting entity" do
    attrs = build_contract_attrs
    with_mocked_adapter([ attrs ]) do |ds, _|
      assert_difference "Entity.count", 2 do
        PublicContracts::ImportService.new(ds).call
      end
    end
  end

  test "call creates winner entity and contract_winner" do
    attrs = build_contract_attrs
    with_mocked_adapter([ attrs ]) do |ds, _|
      assert_difference "ContractWinner.count", 1 do
        PublicContracts::ImportService.new(ds).call
      end
    end
  end

  test "call imports all supported contract fields" do
    attrs = build_contract_attrs
    with_mocked_adapter([ attrs ]) do |ds, _|
      PublicContracts::ImportService.new(ds).call
      contract = Contract.find_by!(external_id: attrs["external_id"], country_code: "PT")

      assert_equal attrs["object"], contract.object
      assert_equal attrs["contract_type"], contract.contract_type
      assert_equal attrs["procedure_type"], contract.procedure_type
      assert_equal attrs["publication_date"], contract.publication_date
      assert_equal attrs["celebration_date"], contract.celebration_date
      assert_equal BigDecimal("15000.0"), contract.base_price
      assert_equal BigDecimal("14500.0"), contract.total_effective_price
      assert_equal attrs["cpv_code"], contract.cpv_code
      assert_equal attrs["location"], contract.location
    end
  end

  test "call sets data_source on contract" do
    attrs = build_contract_attrs
    with_mocked_adapter([ attrs ]) do |ds, _|
      PublicContracts::ImportService.new(ds).call
      contract = Contract.find_by(external_id: attrs["external_id"])
      assert_equal ds.id, contract.data_source_id
    end
  end

  test "call sets country_code from attrs" do
    attrs = build_contract_attrs("country_code" => "PT")
    with_mocked_adapter([ attrs ]) do |ds, _|
      PublicContracts::ImportService.new(ds).call
      contract = Contract.find_by(external_id: attrs["external_id"])
      assert_equal "PT", contract.country_code
    end
  end

  test "call falls back to data_source country_code when attrs has none" do
    attrs = build_contract_attrs.tap { |a| a.delete("country_code") }
    with_mocked_adapter([ attrs ]) do |ds, _|
      PublicContracts::ImportService.new(ds).call
      contract = Contract.find_by(external_id: attrs["external_id"])
      assert_equal ds.country_code, contract.country_code
    end
  end

  test "call sets status to active and updates last_synced_at" do
    with_mocked_adapter([]) do |ds, _|
      PublicContracts::ImportService.new(ds).call
      ds.reload
      assert ds.active?
      assert_not_nil ds.last_synced_at
    end
  end

  test "call updates record_count" do
    attrs1 = build_contract_attrs
    attrs2 = build_contract_attrs
    with_mocked_adapter([ attrs1, attrs2 ]) do |ds, _|
      PublicContracts::ImportService.new(ds).call
      assert_equal 2, ds.reload.record_count
    end
  end

  test "call is idempotent for same external_id" do
    attrs = build_contract_attrs
    with_mocked_adapter([ attrs ]) do |ds, _|
      PublicContracts::ImportService.new(ds).call
    end
    adapter2 = Minitest::Mock.new
    adapter2.expect(:fetch_contracts, [ attrs ])
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter2) do
      assert_no_difference "Contract.count" do
        PublicContracts::ImportService.new(ds).call
      end
    end
    adapter2.verify
  end

  test "call dedupes globally across data sources and backfills missing fields" do
    partial_attrs = build_contract_attrs(
      "external_id" => "shared-123",
      "country_code" => "pt",
      "contract_type" => nil,
      "celebration_date" => nil,
      "cpv_code" => nil,
      "location" => nil
    )
    full_attrs = build_contract_attrs(
      "external_id" => "shared-123",
      "country_code" => "PT",
      "contract_type" => "Aquisição de Serviços",
      "celebration_date" => Date.new(2025, 1, 12),
      "cpv_code" => "72224000",
      "location" => "Lisboa"
    )

    ds_quem = data_sources(:quem_fatura_pt)
    adapter_quem = Minitest::Mock.new
    adapter_quem.expect(:fetch_contracts, [ partial_attrs ])
    ds_quem.stub(:adapter, adapter_quem) do
      assert_difference "Contract.count", 1 do
        PublicContracts::ImportService.new(ds_quem).call
      end
    end
    adapter_quem.verify

    ds_base = data_sources(:portal_base)
    adapter_base = Minitest::Mock.new
    adapter_base.expect(:fetch_contracts, [ full_attrs ])
    ds_base.stub(:adapter, adapter_base) do
      assert_no_difference "Contract.count" do
        PublicContracts::ImportService.new(ds_base).call
      end
    end
    adapter_base.verify

    contract = Contract.find_by!(external_id: "shared-123", country_code: "PT")
    assert_equal "Aquisição de Serviços", contract.contract_type
    assert_equal Date.new(2025, 1, 12), contract.celebration_date
    assert_equal "72224000", contract.cpv_code
    assert_equal "Lisboa", contract.location
  end

  test "call dedupes across sources by natural key when external_id differs" do
    first_attrs = build_contract_attrs(
      "external_id" => "sns-like-001",
      "country_code" => "PT",
      "object" => "Aquisição de reagentes laboratoriais",
      "publication_date" => Date.new(2025, 2, 1),
      "celebration_date" => Date.new(2025, 2, 3),
      "base_price" => 12345.67,
      "contract_type" => nil,
      "cpv_code" => nil,
      "location" => nil,
      "winners" => [ { "tax_identifier" => "509888001", "name" => "Empresa Vencedora Lda", "is_company" => true } ]
    )
    second_attrs = first_attrs.merge(
      "external_id" => "quemfatura-77",
      "contract_type" => "Aquisição de Serviços",
      "cpv_code" => "33140000",
      "location" => "Porto"
    )

    ds_a = data_sources(:sns_pt)
    adapter_a = Minitest::Mock.new
    adapter_a.expect(:fetch_contracts, [ first_attrs ])
    ds_a.stub(:adapter, adapter_a) do
      assert_difference "Contract.count", 1 do
        PublicContracts::ImportService.new(ds_a).call
      end
    end
    adapter_a.verify

    ds_b = data_sources(:quem_fatura_pt)
    adapter_b = Minitest::Mock.new
    adapter_b.expect(:fetch_contracts, [ second_attrs ])
    ds_b.stub(:adapter, adapter_b) do
      assert_no_difference "Contract.count" do
        PublicContracts::ImportService.new(ds_b).call
      end
    end
    adapter_b.verify

    contract = Contract.find_by!(external_id: "sns-like-001", country_code: "PT")
    assert_equal "Aquisição de Serviços", contract.contract_type
    assert_equal "33140000", contract.cpv_code
    assert_equal "Porto", contract.location
    assert_equal 1, Contract.where(country_code: "PT", object: "Aquisição de reagentes laboratoriais").count
  end

  test "call does not natural-dedupe when winner set differs" do
    base_attrs = build_contract_attrs(
      "external_id" => "source-a-1",
      "object" => "Serviço técnico especializado",
      "publication_date" => Date.new(2025, 3, 1),
      "celebration_date" => Date.new(2025, 3, 2),
      "base_price" => 9999.99,
      "winners" => [ { "tax_identifier" => "501111111", "name" => "Fornecedor A", "is_company" => true } ]
    )
    different_winner_attrs = base_attrs.merge(
      "external_id" => "source-b-2",
      "winners" => [ { "tax_identifier" => "502222222", "name" => "Fornecedor B", "is_company" => true } ]
    )

    ds = data_sources(:portal_base)
    adapter1 = Minitest::Mock.new
    adapter1.expect(:fetch_contracts, [ base_attrs ])
    ds.stub(:adapter, adapter1) do
      PublicContracts::ImportService.new(ds).call
    end
    adapter1.verify

    adapter2 = Minitest::Mock.new
    adapter2.expect(:fetch_contracts, [ different_winner_attrs ])
    ds.stub(:adapter, adapter2) do
      assert_difference "Contract.count", 1 do
        PublicContracts::ImportService.new(ds).call
      end
    end
    adapter2.verify
  end

  test "call natural-dedupes with a single candidate when winners are absent" do
    attrs_a = build_contract_attrs(
      "external_id" => "source-a-no-winner",
      "object" => "Fornecimento especializado sem adjudicatário identificado",
      "publication_date" => Date.new(2025, 4, 10),
      "celebration_date" => nil,
      "base_price" => 4444.44,
      "winners" => []
    )
    attrs_b = attrs_a.merge("external_id" => "source-b-no-winner")

    ds = data_sources(:portal_base)
    adapter1 = Minitest::Mock.new
    adapter1.expect(:fetch_contracts, [ attrs_a ])
    ds.stub(:adapter, adapter1) { PublicContracts::ImportService.new(ds).call }
    adapter1.verify

    adapter2 = Minitest::Mock.new
    adapter2.expect(:fetch_contracts, [ attrs_b ])
    ds.stub(:adapter, adapter2) do
      assert_no_difference "Contract.count" do
        PublicContracts::ImportService.new(ds).call
      end
    end
    adapter2.verify
  end

  test "call does not natural-dedupe when both publication and celebration dates are missing" do
    attrs_a = build_contract_attrs(
      "external_id" => "source-a-no-dates",
      "object" => "Contrato sem datas",
      "publication_date" => nil,
      "celebration_date" => nil,
      "base_price" => 3333.33
    )
    attrs_b = attrs_a.merge("external_id" => "source-b-no-dates")

    ds = data_sources(:portal_base)
    adapter1 = Minitest::Mock.new
    adapter1.expect(:fetch_contracts, [ attrs_a ])
    ds.stub(:adapter, adapter1) { PublicContracts::ImportService.new(ds).call }
    adapter1.verify

    adapter2 = Minitest::Mock.new
    adapter2.expect(:fetch_contracts, [ attrs_b ])
    ds.stub(:adapter, adapter2) do
      assert_difference "Contract.count", 1 do
        PublicContracts::ImportService.new(ds).call
      end
    end
    adapter2.verify
  end

  test "call skips contract when object is blank" do
    attrs = build_contract_attrs("object" => "")
    with_mocked_adapter([ attrs ]) do |ds, _|
      assert_no_difference "Contract.count" do
        PublicContracts::ImportService.new(ds).call
      end
    end
  end

  test "call skips contract when contracting_entity has blank tax_id" do
    attrs = build_contract_attrs(
      "contracting_entity" => { "tax_identifier" => "", "name" => "X" }
    )
    with_mocked_adapter([ attrs ]) do |ds, _|
      assert_no_difference "Contract.count" do
        PublicContracts::ImportService.new(ds).call
      end
    end
  end

  test "call skips contract when contracting_entity has blank name" do
    attrs = build_contract_attrs(
      "contracting_entity" => { "tax_identifier" => "123456789", "name" => "" }
    )
    with_mocked_adapter([ attrs ]) do |ds, _|
      assert_no_difference "Contract.count" do
        PublicContracts::ImportService.new(ds).call
      end
    end
  end

  test "call skips winner with blank tax_id" do
    attrs = build_contract_attrs(
      "winners" => [ { "tax_identifier" => "", "name" => "X" } ]
    )
    with_mocked_adapter([ attrs ]) do |ds, _|
      assert_no_difference "ContractWinner.count" do
        PublicContracts::ImportService.new(ds).call
      end
    end
  end

  # ── call_all ───────────────────────────────────────────────────────────────

  test "call_all paginates until adapter returns empty batch" do
    attrs = build_contract_attrs
    adapter = Object.new
    call_count = 0
    adapter.define_singleton_method(:total_count) { 1 }
    adapter.define_singleton_method(:fetch_contracts) do |page: 1, limit: 100|
      call_count += 1
      call_count == 1 ? [ attrs ] : []
    end
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      assert_difference "Contract.count", 1 do
        PublicContracts::ImportService.new(ds).call_all(progress: nil)
      end
      assert_equal 1, ds.reload.record_count
      assert ds.active?
    end
  end

  test "call_all prints progress when progress object and total_count are provided" do
    attrs = build_contract_attrs
    adapter = Object.new
    call_count = 0
    adapter.define_singleton_method(:total_count) { 1 }
    adapter.define_singleton_method(:fetch_contracts) do |page: 1, limit: 100|
      call_count += 1
      call_count == 1 ? [ attrs ] : []
    end
    progress = StringIO.new
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      PublicContracts::ImportService.new(ds).call_all(progress: progress)
    end
    assert_match(/imported/, progress.string)
    assert_match(/Done/, progress.string)
  end

  test "call_all prints progress without total when adapter has no total_count" do
    attrs = build_contract_attrs
    adapter = Object.new
    call_count = 0
    # Adapter deliberately does NOT define total_count
    adapter.define_singleton_method(:fetch_contracts) do |page: 1, limit: 100|
      call_count += 1
      call_count == 1 ? [ attrs ] : []
    end
    progress = StringIO.new
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      PublicContracts::ImportService.new(ds).call_all(progress: progress)
    end
    assert_match(/imported/, progress.string)
    assert_match(/Done/, progress.string)
  end

  test "call_all sleeps between pages when adapter responds to inter_page_delay" do
    attrs = build_contract_attrs
    adapter = Object.new
    call_count = 0
    adapter.define_singleton_method(:total_count)      { 1 }
    adapter.define_singleton_method(:inter_page_delay) { 0 }
    adapter.define_singleton_method(:fetch_contracts) do |page: 1, limit: 100|
      call_count += 1
      call_count == 1 ? [ attrs ] : []
    end
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      assert_difference "Contract.count", 1 do
        PublicContracts::ImportService.new(ds).call_all(progress: nil)
      end
    end
  end

  test "call_all sets status to error when adapter raises" do
    adapter = Object.new
    adapter.define_singleton_method(:total_count) { raise RuntimeError, "boom" }
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      assert_raises(RuntimeError) do
        PublicContracts::ImportService.new(ds).call_all(progress: nil)
      end
    end
    assert ds.reload.error?
  end

  test "call_all delegates to call_streaming when adapter responds to each_contract" do
    attrs = build_contract_attrs
    adapter = Object.new
    each_contract_called = false
    adapter.define_singleton_method(:each_contract) do |&blk|
      each_contract_called = true
      blk.call(attrs)
    end
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      assert_difference "Contract.count", 1 do
        PublicContracts::ImportService.new(ds).call_all(progress: nil)
      end
    end
    assert each_contract_called, "expected each_contract to be called"
  end

  # ── call_streaming ─────────────────────────────────────────────────────

  test "call_streaming imports all contracts yielded by each_contract" do
    attrs1 = build_contract_attrs("object" => "Serviços de consultoria alfa")
    attrs2 = build_contract_attrs("object" => "Serviços de consultoria beta")
    adapter = Object.new
    adapter.define_singleton_method(:each_contract) { |&blk| [ attrs1, attrs2 ].each { |a| blk.call(a) } }
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      assert_difference "Contract.count", 2 do
        PublicContracts::ImportService.new(ds).call_streaming(progress: nil)
      end
      assert_equal 2, ds.reload.record_count
      assert ds.active?
    end
  end

  test "call_streaming caches entities across rows" do
    shared_nif = "500099001"
    attrs1 = build_contract_attrs(
      "contracting_entity" => { "tax_identifier" => shared_nif, "name" => "Entidade Cache Teste", "is_public_body" => true },
      "winners" => []
    )
    attrs2 = build_contract_attrs(
      "contracting_entity" => { "tax_identifier" => shared_nif, "name" => "Entidade Cache Teste", "is_public_body" => true },
      "winners" => []
    )
    adapter = Object.new
    adapter.define_singleton_method(:each_contract) { |&blk| [ attrs1, attrs2 ].each { |a| blk.call(a) } }
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      assert_difference "Entity.count", 1 do
        PublicContracts::ImportService.new(ds).call_streaming(progress: nil)
      end
    end
  end

  test "call_streaming skips duplicate rows without crashing" do
    same_attrs = build_contract_attrs("external_id" => "dup-001")
    adapter = Object.new
    # yield the same external_id twice (simulates duplicate rows within an XLSX)
    adapter.define_singleton_method(:each_contract) { |&blk| 2.times { blk.call(same_attrs) } }
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      assert_difference "Contract.count", 1 do
        PublicContracts::ImportService.new(ds).call_streaming(progress: nil)
      end
    end
  end

  test "call_streaming silently ignores in-batch duplicates via insert_all" do
    # Yield the same external_id twice in a single batch. insert_all's
    # ON CONFLICT DO NOTHING absorbs the second row — no exception raised.
    same_attrs = build_contract_attrs("external_id" => "force-skip-001")
    adapter = Object.new
    adapter.define_singleton_method(:each_contract) { |&blk| 2.times { blk.call(same_attrs) } }
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      assert_difference "Contract.count", 1 do
        PublicContracts::ImportService.new(ds).call_streaming(batch_size: 10, progress: nil)
      end
    end
  end

  test "call_streaming skips batch where all rows have blank object (valid_rows guard)" do
    # All rows have a blank object — filter_map returns empty valid_rows, so
    # flush_bulk returns early with 0 imported.
    attrs = build_contract_attrs("object" => "")
    adapter = Object.new
    adapter.define_singleton_method(:each_contract) { |&blk| blk.call(attrs) }
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      assert_no_difference "Contract.count" do
        PublicContracts::ImportService.new(ds).call_streaming(progress: nil)
      end
      assert_equal 0, ds.reload.record_count
    end
  end

  test "call_streaming skips batch where contracting entity has blank name (contract_rows guard)" do
    # contracting_entity has blank name → find_or_create_entity_cached returns nil
    # → next unless contracting filters every row → contract_rows is empty → early return.
    attrs = build_contract_attrs(
      "contracting_entity" => { "tax_identifier" => "500000002", "name" => "", "is_public_body" => true }
    )
    adapter = Object.new
    adapter.define_singleton_method(:each_contract) { |&blk| blk.call(attrs) }
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      assert_no_difference "Contract.count" do
        PublicContracts::ImportService.new(ds).call_streaming(progress: nil)
      end
    end
  end

  test "call_streaming skips winner when entity not resolvable (blank winner name)" do
    # Winner has a blank name — find_or_create_entity_cached returns nil —
    # next unless winner skips it — no ContractWinner row created.
    attrs = build_contract_attrs(
      "winners" => [ { "tax_identifier" => "509000001", "name" => "", "is_company" => true } ]
    )
    adapter = Object.new
    adapter.define_singleton_method(:each_contract) { |&blk| blk.call(attrs) }
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      assert_difference "Contract.count", 1 do
        assert_no_difference "ContractWinner.count" do
          PublicContracts::ImportService.new(ds).call_streaming(progress: nil)
        end
      end
    end
  end

  test "call_streaming prints progress including skipped count" do
    attrs = build_contract_attrs
    adapter = Object.new
    adapter.define_singleton_method(:each_contract) { |&blk| blk.call(attrs) }
    progress = StringIO.new
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      PublicContracts::ImportService.new(ds).call_streaming(progress: progress)
    end
    assert_match(/imported/, progress.string)
    assert_match(/skipped/, progress.string)
    assert_match(/Done/, progress.string)
  end

  test "call_streaming uses total_count for progress when available" do
    attrs = build_contract_attrs
    adapter = Object.new
    adapter.define_singleton_method(:total_count) { 42 }
    adapter.define_singleton_method(:each_contract) { |&blk| blk.call(attrs) }
    progress = StringIO.new
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      PublicContracts::ImportService.new(ds).call_streaming(progress: progress)
    end
    assert_match %r{1/42}, progress.string
  end

  test "call_streaming raises when adapter lacks each_contract" do
    adapter = Object.new
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      assert_raises(ArgumentError) do
        PublicContracts::ImportService.new(ds).call_streaming(progress: nil)
      end
    end
  end

  test "call_streaming sets status to error on unexpected exception" do
    adapter = Object.new
    adapter.define_singleton_method(:each_contract) { |&_blk| raise RuntimeError, "disk full" }
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      assert_raises(RuntimeError) do
        PublicContracts::ImportService.new(ds).call_streaming(progress: nil)
      end
    end
    assert ds.reload.error?
  end

  # ── error handling ─────────────────────────────────────────────────────────

  test "call sets status to error when adapter raises" do
    adapter = Minitest::Mock.new
    adapter.expect(:fetch_contracts, nil) { raise RuntimeError, "API down" }
    ds = data_sources(:portal_base)
    ds.stub(:adapter, adapter) do
      assert_raises(RuntimeError) do
        PublicContracts::ImportService.new(ds).call
      end
    end
    assert ds.reload.error?
  end
end
