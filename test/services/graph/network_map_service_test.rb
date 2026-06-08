# frozen_string_literal: true

require "test_helper"

class Graph::NetworkMapServiceTest < ActiveSupport::TestCase
  test "call returns global node map with flagged exposure summary" do
    authority = Entity.create!(
      name: "Service Network Authority",
      tax_identifier: "570000101",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    supplier = Entity.create!(
      name: "Service Network Supplier",
      tax_identifier: "570000102",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    flagged_contract = Contract.create!(
      external_id: "service-network-flagged",
      country_code: "PT",
      object: "Flagged service contract",
      contracting_entity: authority,
      publication_date: Date.new(2033, 1, 10),
      celebration_date: Date.new(2033, 1, 11),
      base_price: 300
    )
    ContractWinner.create!(contract: flagged_contract, entity: supplier, price_share: 300)
    Flag.create!(
      contract: flagged_contract,
      flag_type: "A5_THRESHOLD_SPLIT",
      severity: "medium",
      score: 5,
      fired_at: Time.current
    )

    clean_contract = Contract.create!(
      external_id: "service-network-clean",
      country_code: "PT",
      object: "Clean service contract",
      contracting_entity: authority,
      publication_date: Date.new(2033, 1, 12),
      celebration_date: Date.new(2033, 1, 13),
      base_price: 120
    )
    ContractWinner.create!(contract: clean_contract, entity: supplier, price_share: 120)

    payload = Graph::NetworkMapService.new(
      date_from: "2033-01-01",
      date_to: "2033-12-31",
      node_limit: 40
    ).call

    assert payload.key?(:nodes)
    assert payload.key?(:edges)
    assert payload.key?(:meta)

    assert payload[:nodes].any? { |node| node[:label] == authority.name }
    assert payload[:nodes].any? { |node| node[:label] == supplier.name }

    edge = payload[:edges].find { |candidate| candidate[:source] == "entity-#{authority.id}" && candidate[:target] == "entity-#{supplier.id}" }
    assert_not_nil edge
    assert_equal "award_link", edge[:edge_type]
    assert_equal 2, edge.dig(:metrics, :contract_count)
    assert_equal 1, edge.dig(:metrics, :flagged_contract_count)
    assert_equal 300.0, edge.dig(:metrics, :flagged_total_value)
    assert_equal 5, edge.dig(:metrics, :risk_total_score)

    authority_node = payload[:nodes].find { |node| node[:label] == authority.name }
    supplier_node = payload[:nodes].find { |node| node[:label] == supplier.name }
    assert_equal 5, authority_node.dig(:metrics, :risk_total_score)
    assert_equal 5, supplier_node.dig(:metrics, :risk_total_score)

    summary = payload.dig(:meta, :summary)
    assert_equal 1, summary[:total_flagged_contract_count]
    assert_equal 300.0, summary[:total_flagged_value]
    assert_equal 5, summary[:total_risk_score]
  end

  test "call keeps individuals hidden in public mode while exposing connected-individual summary" do
    authority = Entity.create!(
      name: "Public Mode Authority",
      tax_identifier: "570000201",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    supplier = Entity.create!(
      name: "Public Mode Supplier",
      tax_identifier: "570000202",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    contract = Contract.create!(
      external_id: "service-network-public",
      country_code: "PT",
      object: "Public mode graph contract",
      contracting_entity: authority,
      publication_date: Date.new(2034, 2, 10),
      celebration_date: Date.new(2034, 2, 11),
      base_price: 200
    )
    ContractWinner.create!(contract: contract, entity: supplier, price_share: 200)

    EntityPersonRole.create!(
      entity: supplier,
      person: people(:joao),
      role_type: "director",
      role_label: "Director",
      source_name: "Registo Comercial",
      active: true
    )

    payload = Graph::NetworkMapService.new(
      date_from: "2034-01-01",
      date_to: "2034-12-31",
      node_limit: 40,
      include_individuals: false
    ).call

    assert_equal false, payload.dig(:meta, :includes_people)
    assert_operator payload.dig(:meta, :summary, :connected_individual_count), :>=, 1
    refute payload[:nodes].any? { |node| node[:node_type] == "individual" }
  end

  test "call exposes aggregate shared-individual edges without person nodes in public mode" do
    authority = Entity.create!(
      name: "Shared Public Authority",
      tax_identifier: "570000211",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    supplier = Entity.create!(
      name: "Shared Public Supplier",
      tax_identifier: "570000212",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    contract = Contract.create!(
      external_id: "service-network-shared-public",
      country_code: "PT",
      object: "Shared public graph contract",
      contracting_entity: authority,
      publication_date: Date.new(2034, 4, 10),
      celebration_date: Date.new(2034, 4, 11),
      base_price: 205
    )
    ContractWinner.create!(contract: contract, entity: supplier, price_share: 205)

    person = Person.create!(name: "Shared Public Person", tax_identifier: "570000299", country_code: "PT")
    EntityPersonRole.create!(
      entity: authority,
      person: person,
      role_type: "manager",
      role_label: "Manager",
      source_name: "Registo Comercial",
      active: true
    )
    EntityPersonRole.create!(
      entity: supplier,
      person: person,
      role_type: "director",
      role_label: "Director",
      source_name: "Registo Comercial",
      active: true
    )

    payload = Graph::NetworkMapService.new(
      date_from: "2034-04-01",
      date_to: "2034-04-30",
      include_individuals: false
    ).call

    shared_edge = payload[:edges].find { |edge| edge[:edge_type] == "shared_individual_link" }
    assert_not_nil shared_edge
    assert_equal 1, shared_edge.dig(:metrics, :shared_individual_count)
    assert_equal false, payload.dig(:meta, :includes_people)
    refute payload[:nodes].any? { |node| node[:node_type] == "individual" }
  end

  test "call includes pseudonymized individuals when individual mode is enabled" do
    authority = Entity.create!(
      name: "Auth Mode Authority",
      tax_identifier: "570000301",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    supplier = Entity.create!(
      name: "Auth Mode Supplier",
      tax_identifier: "570000302",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    contract = Contract.create!(
      external_id: "service-network-auth",
      country_code: "PT",
      object: "Auth mode graph contract",
      contracting_entity: authority,
      publication_date: Date.new(2035, 3, 10),
      celebration_date: Date.new(2035, 3, 11),
      base_price: 210
    )
    ContractWinner.create!(contract: contract, entity: supplier, price_share: 210)

    EntityPersonRole.create!(
      entity: supplier,
      person: people(:maria),
      role_type: "officer",
      role_label: "Fiscal Único",
      source_name: "Registo Comercial",
      active: true
    )

    payload = Graph::NetworkMapService.new(
      date_from: "2035-01-01",
      date_to: "2035-12-31",
      node_limit: 40,
      include_individuals: true
    ).call

    assert_equal true, payload.dig(:meta, :includes_people)
    assert_equal "person_scoped_pseudonym", payload.dig(:meta, :anonymization_mode)

    individual_node = payload[:nodes].find { |node| node[:node_type] == "individual" }
    assert_not_nil individual_node
    assert_match(/\[P-[0-9a-f]{4}\]/, individual_node[:label])
    refute_includes individual_node[:label], people(:maria).name

    role_edge = payload[:edges].find { |edge| edge[:edge_type] == "entity_role_link" }
    assert_not_nil role_edge
  end

  test "call applies node type filters" do
    company_buyer = Entity.create!(
      name: "Company Buyer",
      tax_identifier: "570000401",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    company_supplier = Entity.create!(
      name: "Company Supplier",
      tax_identifier: "570000402",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    contract = Contract.create!(
      external_id: "service-network-company-filter",
      country_code: "PT",
      object: "Company-only graph contract",
      contracting_entity: company_buyer,
      publication_date: Date.new(2036, 4, 10),
      celebration_date: Date.new(2036, 4, 11),
      base_price: 190
    )
    ContractWinner.create!(contract: contract, entity: company_supplier, price_share: 190)

    payload = Graph::NetworkMapService.new(
      date_from: "2036-01-01",
      date_to: "2036-12-31",
      include_public_bodies: false,
      include_companies: true
    ).call

    assert_equal [ "company" ], payload[:nodes].map { |node| node[:node_type] }.uniq
    assert payload[:edges].any? { |edge| edge[:source] == "entity-#{company_buyer.id}" && edge[:target] == "entity-#{company_supplier.id}" }
  end

  test "call includes legacy directors and flagged individual metrics" do
    authority = Entity.create!(
      name: "Legacy Director Authority",
      tax_identifier: "570000501",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    supplier = Entity.create!(
      name: "Legacy Director Supplier",
      tax_identifier: "570000502",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    contract = Contract.create!(
      external_id: "service-network-legacy-director",
      country_code: "PT",
      object: "Legacy director graph contract",
      contracting_entity: authority,
      publication_date: Date.new(2037, 5, 10),
      celebration_date: Date.new(2037, 5, 11),
      base_price: 250
    )
    ContractWinner.create!(contract: contract, entity: supplier, price_share: 250)
    Flag.create!(
      contract: contract,
      flag_type: "A5_THRESHOLD_SPLIT",
      severity: "medium",
      score: 6,
      fired_at: Time.current
    )
    CompanyDirector.create!(
      entity: supplier,
      name: "Legacy Director",
      role: nil,
      country_code: "PT"
    )

    payload = Graph::NetworkMapService.new(
      date_from: "2037-01-01",
      date_to: "2037-12-31",
      include_individuals: true
    ).call

    individual_node = payload[:nodes].find { |node| node[:node_type] == "individual" }
    assert_not_nil individual_node
    assert_equal "Director", individual_node.dig(:metrics, :role_label)
    assert_equal "Legacy Directors", individual_node.dig(:metrics, :source_name)
    assert_equal 6, individual_node.dig(:metrics, :risk_total_score)
    assert_equal 1, individual_node.dig(:metrics, :risk_flagged_contract_count)
    assert_equal 250.0, individual_node.dig(:metrics, :risk_flagged_total_value)
  end

  test "call isolates network to forced entity neighborhood" do
    focus_authority = Entity.create!(
      name: "Isolated Focus Authority",
      tax_identifier: "570000601",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    focus_supplier = Entity.create!(
      name: "Isolated Focus Supplier",
      tax_identifier: "570000602",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    outside_authority = Entity.create!(
      name: "Outside Authority",
      tax_identifier: "570000603",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    outside_supplier = Entity.create!(
      name: "Outside Supplier",
      tax_identifier: "570000604",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    focus_contract = Contract.create!(
      external_id: "service-network-isolate-focus",
      country_code: "PT",
      object: "Focus network contract",
      contracting_entity: focus_authority,
      publication_date: Date.new(2039, 7, 10),
      celebration_date: Date.new(2039, 7, 11),
      base_price: 300
    )
    ContractWinner.create!(contract: focus_contract, entity: focus_supplier, price_share: 300)

    outside_contract = Contract.create!(
      external_id: "service-network-isolate-outside",
      country_code: "PT",
      object: "Outside network contract",
      contracting_entity: outside_authority,
      publication_date: Date.new(2039, 7, 12),
      celebration_date: Date.new(2039, 7, 13),
      base_price: 400
    )
    ContractWinner.create!(contract: outside_contract, entity: outside_supplier, price_share: 400)

    payload = Graph::NetworkMapService.new(
      date_from: "2039-01-01",
      date_to: "2039-12-31",
      isolate_network: true,
      must_include_entity_ids: [ focus_authority.id ]
    ).call

    labels = payload[:nodes].map { |node| node[:label] }
    assert_includes labels, focus_authority.name
    assert_includes labels, focus_supplier.name
    refute_includes labels, outside_authority.name
    refute_includes labels, outside_supplier.name
    assert_equal true, payload.dig(:meta, :filters, :isolate_network)
  end

  test "call isolate mode keeps induced first-hop subgraph via recursive CTE" do
    focus = Entity.create!(
      name: "Recursive Focus Authority",
      tax_identifier: "579300201",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    neighbor_a = Entity.create!(
      name: "Recursive Neighbor A",
      tax_identifier: "579300202",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    neighbor_b = Entity.create!(
      name: "Recursive Neighbor B",
      tax_identifier: "579300203",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    outside = Entity.create!(
      name: "Recursive Outside",
      tax_identifier: "579300204",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    contract_focus_a = Contract.create!(
      external_id: "service-network-recursive-focus-a",
      country_code: "PT",
      object: "Focus to A",
      contracting_entity: focus,
      publication_date: Date.new(2042, 5, 10),
      celebration_date: Date.new(2042, 5, 11),
      base_price: 110
    )
    ContractWinner.create!(contract: contract_focus_a, entity: neighbor_a, price_share: 110)

    contract_focus_b = Contract.create!(
      external_id: "service-network-recursive-focus-b",
      country_code: "PT",
      object: "Focus to B",
      contracting_entity: focus,
      publication_date: Date.new(2042, 5, 11),
      celebration_date: Date.new(2042, 5, 12),
      base_price: 120
    )
    ContractWinner.create!(contract: contract_focus_b, entity: neighbor_b, price_share: 120)

    contract_neighbor_link = Contract.create!(
      external_id: "service-network-recursive-neighbor-link",
      country_code: "PT",
      object: "A to B",
      contracting_entity: neighbor_a,
      publication_date: Date.new(2042, 5, 12),
      celebration_date: Date.new(2042, 5, 13),
      base_price: 90
    )
    ContractWinner.create!(contract: contract_neighbor_link, entity: neighbor_b, price_share: 90)

    contract_outside = Contract.create!(
      external_id: "service-network-recursive-outside",
      country_code: "PT",
      object: "B to outside",
      contracting_entity: neighbor_b,
      publication_date: Date.new(2042, 5, 13),
      celebration_date: Date.new(2042, 5, 14),
      base_price: 130
    )
    ContractWinner.create!(contract: contract_outside, entity: outside, price_share: 130)

    payload = Graph::NetworkMapService.new(
      date_from: "2042-01-01",
      date_to: "2042-12-31",
      isolate_network: true,
      must_include_entity_ids: [ focus.id ],
      include_public_bodies: true,
      include_companies: true
    ).call

    labels = payload[:nodes].map { |node| node[:label] }
    assert_includes labels, focus.name
    assert_includes labels, neighbor_a.name
    assert_includes labels, neighbor_b.name
    refute_includes labels, outside.name

    edge_ids = payload[:edges].map { |edge| edge[:id] }
    assert_includes edge_ids, "edge-#{focus.id}-#{neighbor_a.id}"
    assert_includes edge_ids, "edge-#{focus.id}-#{neighbor_b.id}"
    assert_includes edge_ids, "edge-#{neighbor_a.id}-#{neighbor_b.id}"
    refute_includes edge_ids, "edge-#{neighbor_b.id}-#{outside.id}"
  end

  test "call reads pre-aggregated edge summaries with date, source, node-type, and isolate filters" do
    GraphEdgeDailySummary.delete_all
    Rails.cache.delete("graph/network_map/preaggregated_edges_available")

    focus_source = Entity.create!(
      name: "Summary Focus Source",
      tax_identifier: "579100201",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    included_target = Entity.create!(
      name: "Summary Included Target",
      tax_identifier: "579100202",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    outside_source = Entity.create!(
      name: "Summary Outside Source",
      tax_identifier: "579100203",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    public_source = Entity.create!(
      name: "Summary Public Source",
      tax_identifier: "579100204",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )

    GraphEdgeDailySummary.create!(
      source_entity: focus_source,
      target_entity: included_target,
      publication_date: Date.new(2040, 3, 15),
      data_source: data_sources(:portal_base),
      contract_count: 3,
      total_value: 600,
      flagged_contract_count: 2,
      flagged_total_value: 450,
      risk_total_score: 9,
      source_is_public_body: false,
      source_is_company: true,
      target_is_public_body: false,
      target_is_company: true,
      computed_at: Time.current
    )
    GraphEdgeDailySummary.create!(
      source_entity: focus_source,
      target_entity: included_target,
      publication_date: Date.new(2039, 12, 20),
      data_source: data_sources(:portal_base),
      contract_count: 8,
      total_value: 999,
      flagged_contract_count: 8,
      flagged_total_value: 999,
      risk_total_score: 99,
      source_is_public_body: false,
      source_is_company: true,
      target_is_public_body: false,
      target_is_company: true,
      computed_at: Time.current
    )
    GraphEdgeDailySummary.create!(
      source_entity: outside_source,
      target_entity: included_target,
      publication_date: Date.new(2040, 3, 15),
      data_source: data_sources(:portal_base),
      contract_count: 4,
      total_value: 700,
      flagged_contract_count: 1,
      flagged_total_value: 200,
      risk_total_score: 5,
      source_is_public_body: false,
      source_is_company: true,
      target_is_public_body: false,
      target_is_company: true,
      computed_at: Time.current
    )
    GraphEdgeDailySummary.create!(
      source_entity: public_source,
      target_entity: included_target,
      publication_date: Date.new(2040, 3, 15),
      data_source: data_sources(:portal_base),
      contract_count: 4,
      total_value: 800,
      flagged_contract_count: 1,
      flagged_total_value: 100,
      risk_total_score: 4,
      source_is_public_body: true,
      source_is_company: false,
      target_is_public_body: false,
      target_is_company: true,
      computed_at: Time.current
    )
    GraphEdgeDailySummary.create!(
      source_entity: focus_source,
      target_entity: included_target,
      publication_date: Date.new(2040, 3, 15),
      data_source: data_sources(:sns_pt),
      contract_count: 2,
      total_value: 900,
      flagged_contract_count: 2,
      flagged_total_value: 900,
      risk_total_score: 20,
      source_is_public_body: false,
      source_is_company: true,
      target_is_public_body: false,
      target_is_company: true,
      computed_at: Time.current
    )

    payload = Graph::NetworkMapService.new(
      date_from: "2040-01-01",
      date_to: "2040-12-31",
      include_public_bodies: false,
      include_companies: true,
      data_source_ids: [ data_sources(:portal_base).id ],
      isolate_network: true,
      must_include_entity_ids: [ focus_source.id, public_source.id ]
    ).call

    assert_equal [ focus_source.name, included_target.name, public_source.name ].sort,
           payload[:nodes].map { |node| node[:label] }.sort

    edge = payload[:edges].find do |candidate|
      candidate[:source] == "entity-#{focus_source.id}" && candidate[:target] == "entity-#{included_target.id}"
    end
    assert_not_nil edge
    assert_equal 3, edge.dig(:metrics, :contract_count)
    assert_equal 600.0, edge.dig(:metrics, :total_value)
    assert_equal 2, edge.dig(:metrics, :flagged_contract_count)
    assert_equal 450.0, edge.dig(:metrics, :flagged_total_value)
    assert_equal 9, edge.dig(:metrics, :risk_total_score)
    assert_equal "2040-03-15", edge.dig(:metrics, :latest_publication_date)

    summary = payload.dig(:meta, :summary)
    assert_equal 3, summary[:total_contract_count]
    assert_equal 600.0, summary[:total_value]
    assert_equal 2, summary[:total_flagged_contract_count]
    assert_equal 450.0, summary[:total_flagged_value]
    assert_equal 9, summary[:total_risk_score]
  end

  test "call uses pre-aggregated fast path when no filters are present" do
    GraphEdgeDailySummary.delete_all
    Rails.cache.delete("graph/network_map/preaggregated_edges_available")

    source = Entity.create!(
      name: "Fast Summary Source",
      tax_identifier: "579100301",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    target = Entity.create!(
      name: "Fast Summary Target",
      tax_identifier: "579100302",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    GraphEdgeDailySummary.create!(
      source_entity: source,
      target_entity: target,
      publication_date: Date.new(2041, 4, 1),
      data_source: data_sources(:portal_base),
      contract_count: 5,
      total_value: 1_200,
      flagged_contract_count: 1,
      flagged_total_value: 300,
      risk_total_score: 7,
      source_is_public_body: true,
      source_is_company: false,
      target_is_public_body: false,
      target_is_company: true,
      computed_at: Time.current
    )

    instrumentation = {}
    payload = Graph::NetworkMapService.new(instrumentation: instrumentation).call

    assert_equal "preaggregated_fast", instrumentation[:edge_source]
    assert_equal true, instrumentation[:used_preaggregated_edges]
    assert_includes payload[:nodes].map { |node| node[:label] }, source.name
    assert_includes payload[:nodes].map { |node| node[:label] }, target.name
    assert_equal 5, payload.dig(:meta, :summary, :total_contract_count)
  end

  test "pre-aggregated helpers handle unavailable tables, filters, dates, and isolate scopes" do
    service = Graph::NetworkMapService.new(
      data_source_ids: [ data_sources(:portal_base).id ],
      must_include_entity_ids: [ entities(:one).id ],
      isolate_network: true
    )

    GraphEdgeDailySummary.stub(:exists?, -> { raise ActiveRecord::StatementInvalid, "missing" }) do
      Rails.cache.delete("graph/network_map/preaggregated_edges_available")
      assert_equal false, service.send(:preaggregated_edges_available?)
    end

    assert_equal Contract.where(data_source_id: data_sources(:portal_base).id).count,
                 service.send(:apply_data_source_filter, Contract.all).count
    assert_equal Date.new(2041, 1, 1), service.send(:parse_sql_date, "2041-01-01")
    assert_nil service.send(:parse_sql_date, "not-a-date")

    metrics, = service.send(:entity_contract_mappings, [ entities(:one).id ])
    assert_kind_of Hash, metrics
  end

  test "call handles invalid dates and empty filters" do
    payload = Graph::NetworkMapService.new(
      date_from: "not-a-date",
      include_public_bodies: false,
      include_companies: false
    ).call

    assert_empty payload[:nodes]
    assert_empty payload[:edges]
    assert_nil payload.dig(:meta, :filters, :date_from)
  end

  test "call keeps forced entities for individual role links even without contract edges" do
    authority = Entity.create!(
      name: "Forced Entity Authority",
      tax_identifier: "579000101",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    supplier = Entity.create!(
      name: "Forced Entity Supplier",
      tax_identifier: "579000102",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    side_company_a = Entity.create!(
      name: "Forced Side Company A",
      tax_identifier: "579000103",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    side_company_b = Entity.create!(
      name: "Forced Side Company B",
      tax_identifier: "579000104",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    contract = Contract.create!(
      external_id: "service-network-forced-entities",
      country_code: "PT",
      object: "Forced entities anchor contract",
      contracting_entity: authority,
      publication_date: Date.new(2038, 6, 10),
      celebration_date: Date.new(2038, 6, 11),
      base_price: 100
    )
    ContractWinner.create!(contract: contract, entity: supplier, price_share: 100)

    person = Person.create!(name: "Forced Link Person", tax_identifier: "579000199", country_code: "PT")
    [ supplier, side_company_a, side_company_b ].each do |entity|
      EntityPersonRole.create!(
        entity: entity,
        person: person,
        role_type: "director",
        role_label: "Director",
        source_name: "Registo Comercial",
        active: true
      )
    end

    payload = Graph::NetworkMapService.new(
      date_from: "2038-01-01",
      date_to: "2038-12-31",
      node_limit: 2,
      include_individuals: true,
      must_include_entity_ids: [ side_company_a.id, side_company_b.id ]
    ).call

    assert payload[:nodes].any? { |node| node[:id] == "entity-#{side_company_a.id}" }
    assert payload[:nodes].any? { |node| node[:id] == "entity-#{side_company_b.id}" }

    individual_node = payload[:nodes].find do |node|
      node[:node_type] == "individual" && node.dig(:metrics, :connected_entity_ids)&.include?(side_company_a.id)
    end
    assert_not_nil individual_node
    assert_equal 3, individual_node.dig(:metrics, :connected_entity_count)

    role_edges = payload[:edges].select do |edge|
      edge[:edge_type] == "entity_role_link" && edge[:target] == individual_node[:id]
    end
    assert_equal 3, role_edges.count
  end

  test "individual_records limits role rows per entity" do
    entity = Entity.create!(
      name: "Dense Role Entity",
      tax_identifier: "579000301",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    55.times do |index|
      person = Person.create!(
        name: "Dense Person #{index}",
        tax_identifier: format("57988%04d", index),
        country_code: "PT"
      )

      EntityPersonRole.create!(
        entity: entity,
        person: person,
        role_type: "director",
        role_label: "Director #{index}",
        source_name: "Registo Comercial",
        active: true
      )
    end

    service = Graph::NetworkMapService.new
    records = service.send(:individual_records, [ entity.id ])

    assert_equal Graph::NetworkMapService::INDIVIDUAL_ROLE_LIMIT_PER_ENTITY, records.size
    assert_equal [ entity.id ], records.map { |record| record[:entity_id] }.uniq
  end

  test "format_date returns nil for invalid date strings" do
    service = Graph::NetworkMapService.new

    assert_nil service.send(:format_date, "not-a-date")
  end

  test "individual metric enrichment falls back to connected entity ids on empty grouped records" do
    service = Graph::NetworkMapService.new
    node = {
      id: "individual-manual",
      metrics: {
        connected_entity_ids: [ entities(:one).id ]
      }
    }

    service.send(:enrich_individual_nodes_with_contract_metrics!, [ node ], {}, [ entities(:one).id ])

    assert_operator node.dig(:metrics, :connected_entity_count), :>=, 1
  end

  test "call fills instrumentation hash when provided" do
    authority = Entity.create!(
      name: "Instrumentation Authority",
      tax_identifier: "579400101",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    supplier = Entity.create!(
      name: "Instrumentation Supplier",
      tax_identifier: "579400102",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    contract = Contract.create!(
      external_id: "service-network-instrumentation",
      country_code: "PT",
      object: "Instrumentation contract",
      contracting_entity: authority,
      publication_date: Date.new(2043, 1, 10),
      celebration_date: Date.new(2043, 1, 11),
      base_price: 150
    )
    ContractWinner.create!(contract: contract, entity: supplier, price_share: 150)

    instrumentation = {}
    payload = Graph::NetworkMapService.new(
      date_from: "2043-01-01",
      date_to: "2043-12-31",
      instrumentation: instrumentation
    ).call

    assert_equal payload[:nodes].size, instrumentation[:node_count]
    assert_equal payload[:edges].size, instrumentation[:edge_count]
    assert_includes %w[preaggregated live], instrumentation[:edge_source]
    assert_includes [ true, false ], instrumentation[:used_preaggregated_edges]
    assert_equal false, instrumentation[:include_individuals]
    assert_operator instrumentation[:edge_row_count], :>=, 1
    assert_operator instrumentation.dig(:timings_ms, :total), :>=, 0.0
    assert instrumentation.dig(:timings_ms, :edge_aggregation)
    assert instrumentation.dig(:timings_ms, :node_selection)
  end

  test "individual metric enrichment skips contract lookups for large entity sets" do
    service = Graph::NetworkMapService.new(
      instrumentation: {}
    )

    node = {
      id: "individual-heavy",
      metrics: {
        connected_entity_ids: [ entities(:one).id ]
      }
    }

    grouped_nodes = {
      "individual-heavy" => [
        {
          entity_id: entities(:one).id,
          role_type: "director",
          role_label: "Director",
          source_name: "Registo Comercial",
          active: true,
          start_date: nil,
          end_date: nil,
          pseudonym_seed: "person-1"
        }
      ]
    }

    large_entity_ids = (1..(Graph::NetworkMapService::INDIVIDUAL_CONTRACT_ENRICHMENT_ENTITY_LIMIT + 1)).to_a

    service.stub(:entity_contract_mappings, ->(*) { raise "entity_contract_mappings should not run" }) do
      service.send(:enrich_individual_nodes_with_contract_metrics!, [ node ], grouped_nodes, large_entity_ids)
    end

    assert_equal 0, node.dig(:metrics, :involved_contract_count).to_i
    assert_equal 0.0, node.dig(:metrics, :involved_total_value).to_f
    assert_equal 0, node.dig(:metrics, :risk_total_score).to_i
    assert_equal true, service.instance_variable_get(:@instrumentation)[:individual_contract_enrichment_skipped]
  end
end
