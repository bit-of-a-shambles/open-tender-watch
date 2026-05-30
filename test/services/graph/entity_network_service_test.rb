# frozen_string_literal: true

require "test_helper"

class Graph::EntityNetworkServiceTest < ActiveSupport::TestCase
  test "call returns aggregated graph payload without personal identifiers" do
    payload = Graph::EntityNetworkService.new(entity: entities(:one)).call

    assert payload.key?(:nodes)
    assert payload.key?(:edges)
    assert payload.key?(:meta)

    focus = payload[:nodes].find { |node| node[:is_focus] }
    assert_not_nil focus
    assert_equal "entity-#{entities(:one).id}", focus[:id]

    payload[:nodes].each do |node|
      refute node.key?(:tax_identifier)
    end

    payload[:edges].each do |edge|
      refute edge.key?(:tax_identifier)
    end

    assert_equal false, payload[:meta][:includes_people]
    assert_equal false, payload[:meta][:includes_tax_identifier]
  end

  test "call merges outgoing and incoming links for the same neighbor" do
    focus = Entity.create!(
      name: "Focus Authority",
      tax_identifier: "510000111",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    neighbor = Entity.create!(
      name: "Neighbor Company",
      tax_identifier: "510000222",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    outgoing_contract = Contract.create!(
      external_id: "graph-outgoing-1",
      country_code: "PT",
      object: "Outgoing relation",
      contracting_entity: focus,
      publication_date: Date.new(2026, 3, 10),
      celebration_date: Date.new(2026, 3, 11),
      base_price: 1000
    )
    ContractWinner.create!(contract: outgoing_contract, entity: neighbor, price_share: 1000)

    incoming_contract = Contract.create!(
      external_id: "graph-incoming-1",
      country_code: "PT",
      object: "Incoming relation",
      contracting_entity: neighbor,
      publication_date: Date.new(2026, 3, 12),
      celebration_date: Date.new(2026, 3, 13),
      base_price: 2000
    )
    ContractWinner.create!(contract: incoming_contract, entity: focus, price_share: 2000)

    payload = Graph::EntityNetworkService.new(entity: focus).call
    edge = payload[:edges].find { |e| e[:target] == "entity-#{neighbor.id}" }

    assert_not_nil edge
    assert_equal "bidirectional_award", edge[:edge_type]
    assert_equal 2, edge.dig(:metrics, :contract_count)
    assert_equal 3000.0, edge.dig(:metrics, :total_value)
    assert_equal 1, edge.dig(:metrics, :outgoing_contract_count)
    assert_equal 1, edge.dig(:metrics, :incoming_contract_count)
  end

  test "call labels incoming-only links" do
    focus = Entity.create!(
      name: "Incoming Only Focus",
      tax_identifier: "510000223",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    authority = Entity.create!(
      name: "Incoming Only Authority",
      tax_identifier: "510000224",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )

    contract = Contract.create!(
      external_id: "graph-incoming-only",
      country_code: "PT",
      object: "Incoming only relation",
      contracting_entity: authority,
      publication_date: Date.new(2026, 4, 12),
      celebration_date: Date.new(2026, 4, 13),
      base_price: 700
    )
    ContractWinner.create!(contract: contract, entity: focus, price_share: 700)

    payload = Graph::EntityNetworkService.new(entity: focus).call
    edge = payload[:edges].find { |candidate| candidate[:source] == "entity-#{focus.id}" && candidate[:target] == "entity-#{authority.id}" }

    assert_not_nil edge
    assert_equal "awarded_to_focus", edge[:edge_type]
  end

  test "call applies date filters to relation aggregation" do
    focus = Entity.create!(
      name: "Date Filter Authority",
      tax_identifier: "510000333",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    old_neighbor = Entity.create!(
      name: "Old Neighbor",
      tax_identifier: "510000334",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    recent_neighbor = Entity.create!(
      name: "Recent Neighbor",
      tax_identifier: "510000335",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    old_contract = Contract.create!(
      external_id: "graph-date-old",
      country_code: "PT",
      object: "Old contract",
      contracting_entity: focus,
      publication_date: Date.new(2020, 1, 10),
      celebration_date: Date.new(2020, 1, 12),
      base_price: 111
    )
    ContractWinner.create!(contract: old_contract, entity: old_neighbor, price_share: 111)

    recent_contract = Contract.create!(
      external_id: "graph-date-recent",
      country_code: "PT",
      object: "Recent contract",
      contracting_entity: focus,
      publication_date: Date.new(2026, 2, 10),
      celebration_date: Date.new(2026, 2, 12),
      base_price: 222
    )
    ContractWinner.create!(contract: recent_contract, entity: recent_neighbor, price_share: 222)

    payload = Graph::EntityNetworkService.new(
      entity: focus,
      date_from: "2026-01-01"
    ).call

    node_ids = payload[:nodes].map { |node| node[:entity_id] }
    assert_includes node_ids, recent_neighbor.id
    refute_includes node_ids, old_neighbor.id
  end

  test "call enforces neighbor limit and truncation metadata" do
    focus = Entity.create!(
      name: "Limit Authority",
      tax_identifier: "510000444",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )

    [ 1000, 900, 800 ].each_with_index do |value, idx|
      neighbor = Entity.create!(
        name: "Neighbor #{idx}",
        tax_identifier: "51000044#{idx}",
        country_code: "PT",
        is_public_body: false,
        is_company: true
      )
      contract = Contract.create!(
        external_id: "graph-limit-#{idx}",
        country_code: "PT",
        object: "Limit contract #{idx}",
        contracting_entity: focus,
        publication_date: Date.new(2026, 1, idx + 1),
        celebration_date: Date.new(2026, 1, idx + 2),
        base_price: value
      )
      ContractWinner.create!(contract: contract, entity: neighbor, price_share: value)
    end

    payload = Graph::EntityNetworkService.new(entity: focus, neighbor_limit: 2).call

    assert_equal 2, payload.dig(:meta, :neighbor_limit)
    assert_equal 3, payload.dig(:meta, :total_neighbors)
    assert_equal true, payload.dig(:meta, :truncated)
    assert_equal 3, payload[:nodes].size
  end

  test "call can include anonymized individual nodes without exposing personal identifiers" do
    focus = entities(:one)
    role = EntityPersonRole.create!(
      entity: focus,
      person: people(:joao),
      role_type: "director",
      role_label: "Director",
      source_name: "Registo Comercial",
      active: true,
      start_date: Date.new(2024, 1, 1)
    )

    payload = Graph::EntityNetworkService.new(entity: focus, include_individuals: true).call

    assert_equal true, payload.dig(:meta, :includes_people)
    assert_equal false, payload.dig(:meta, :includes_tax_identifier)
    assert_equal "person_scoped_pseudonym", payload.dig(:meta, :anonymization_mode)

    individual_nodes = payload[:nodes].select { |node| node[:node_type] == "individual" }
    assert individual_nodes.any?

    node = individual_nodes.find { |candidate|
      candidate.dig(:metrics, :role_type) == "director" &&
        candidate.dig(:metrics, :role_label) == "Director" &&
        candidate.dig(:metrics, :source_name) == "Registo Comercial"
    }
    assert_not_nil node
    assert_match(/\[P-[0-9a-f]{4}\]/, node[:label])
    refute_includes node[:label], people(:joao).name
    assert_equal "director", node.dig(:metrics, :role_type)
    assert_equal "Director", node.dig(:metrics, :role_label)
    assert_equal "Registo Comercial", node.dig(:metrics, :source_name)
    assert_equal "2024-01-01", node.dig(:metrics, :start_date)

    role_edge = payload[:edges].find { |edge| edge[:edge_type] == "entity_role_link" }
    assert_not_nil role_edge
    assert_equal role.entity_id, role_edge[:source].delete_prefix("entity-").to_i
  end

  test "call stays read-only when including individuals" do
    EntityPersonRole.create!(
      entity: entities(:one),
      person: people(:maria),
      role_type: "officer",
      role_label: "Fiscal Único",
      source_name: "Registo Comercial",
      active: true
    )

    assert_no_changes -> { Person.count } do
      assert_no_changes -> { EntityPersonRole.count } do
        assert_no_changes -> { CompanyDirector.count } do
          Graph::EntityNetworkService.new(entity: entities(:one), include_individuals: true).call
        end
      end
    end
  end

  test "call includes peer entity relationships among selected neighbors" do
    focus = Entity.create!(
      name: "Peer Focus",
      tax_identifier: "530000101",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    neighbor_a = Entity.create!(
      name: "Peer Neighbor A",
      tax_identifier: "530000102",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    neighbor_b = Entity.create!(
      name: "Peer Neighbor B",
      tax_identifier: "530000103",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )

    focus_to_a = Contract.create!(
      external_id: "peer-focus-a",
      country_code: "PT",
      object: "Focus to A",
      contracting_entity: focus,
      publication_date: Date.new(2026, 1, 10),
      celebration_date: Date.new(2026, 1, 11),
      base_price: 1000
    )
    ContractWinner.create!(contract: focus_to_a, entity: neighbor_a, price_share: 1000)

    focus_to_b = Contract.create!(
      external_id: "peer-focus-b",
      country_code: "PT",
      object: "Focus to B",
      contracting_entity: focus,
      publication_date: Date.new(2026, 1, 12),
      celebration_date: Date.new(2026, 1, 13),
      base_price: 1200
    )
    ContractWinner.create!(contract: focus_to_b, entity: neighbor_b, price_share: 1200)

    a_to_b = Contract.create!(
      external_id: "peer-a-b",
      country_code: "PT",
      object: "A to B",
      contracting_entity: neighbor_a,
      publication_date: Date.new(2026, 2, 1),
      celebration_date: Date.new(2026, 2, 2),
      base_price: 800
    )
    ContractWinner.create!(contract: a_to_b, entity: neighbor_b, price_share: 800)

    payload = Graph::EntityNetworkService.new(entity: focus, neighbor_limit: 2).call

    peer_edge = payload[:edges].find do |edge|
      edge[:edge_type] == "peer_award_link" &&
        edge[:source] == "entity-#{neighbor_a.id}" &&
        edge[:target] == "entity-#{neighbor_b.id}"
    end

    assert_not_nil peer_edge
    assert_equal 1, peer_edge.dig(:metrics, :contract_count)
    assert_equal 800.0, peer_edge.dig(:metrics, :total_value)
  end

  test "call links one anonymized individual node to multiple entities when person is shared" do
    focus = Entity.create!(
      name: "Shared Person Focus",
      tax_identifier: "540000101",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    neighbor = Entity.create!(
      name: "Shared Person Neighbor",
      tax_identifier: "540000102",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    person = Person.create!(
      name: "Shared Director",
      tax_identifier: "540000199",
      country_code: "PT"
    )

    contract = Contract.create!(
      external_id: "shared-person-rel",
      country_code: "PT",
      object: "Focus to neighbor",
      contracting_entity: focus,
      publication_date: Date.new(2026, 3, 1),
      celebration_date: Date.new(2026, 3, 2),
      base_price: 500
    )
    ContractWinner.create!(contract: contract, entity: neighbor, price_share: 500)
    Flag.create!(
      contract: contract,
      flag_type: "A1_REPEAT_DIRECT_AWARD",
      severity: "high",
      score: 8,
      fired_at: Time.current
    )

    EntityPersonRole.create!(
      entity: focus,
      person: person,
      role_type: "director",
      role_label: "Director",
      source_name: "Registo Comercial",
      active: true
    )
    EntityPersonRole.create!(
      entity: neighbor,
      person: person,
      role_type: "director",
      role_label: "Director",
      source_name: "Registo Comercial",
      active: true
    )

    payload = Graph::EntityNetworkService.new(entity: focus, include_individuals: true, neighbor_limit: 1).call

    shared_individual_nodes = payload[:nodes].select { |node| node[:node_type] == "individual" }
    assert_equal 1, shared_individual_nodes.size

    shared_node_id = shared_individual_nodes.first[:id]
    shared_metrics = shared_individual_nodes.first[:metrics]
    shared_edges = payload[:edges].select { |edge| edge[:edge_type] == "entity_role_link" && edge[:target] == shared_node_id }
    edge_sources = shared_edges.map { |edge| edge[:source] }

    assert_includes edge_sources, "entity-#{focus.id}"
    assert_includes edge_sources, "entity-#{neighbor.id}"
    assert_equal 2, shared_metrics[:connected_entity_count]
    assert_equal 1, shared_metrics[:involved_contract_count]
    assert_equal 500.0, shared_metrics[:involved_total_value]
    assert_equal 1, shared_metrics[:risk_flagged_contract_count]
    assert_equal 8, shared_metrics[:risk_total_score]
    assert_equal 1, shared_metrics.dig(:risk_severity_breakdown, "high")
    assert_includes shared_metrics[:connected_entity_labels], focus.name
    assert_includes shared_metrics[:connected_entity_labels], neighbor.name
  end

  test "legacy individual metrics fall back to connected entity ids on empty grouped records" do
    focus = entities(:one)
    service = Graph::EntityNetworkService.new(entity: focus)
    node = {
      id: "individual-manual",
      metrics: {
        connected_entity_ids: [ focus.id ]
      }
    }

    service.send(:enrich_individual_nodes_with_contract_metrics!, [ node ], {}, [ focus.id ])

    assert_operator node.dig(:metrics, :connected_entity_count), :>=, 1
  end

  test "date parsing helpers return nil for invalid strings" do
    service = Graph::EntityNetworkService.new(entity: entities(:one), date_from: "bad-date")

    assert_nil service.instance_variable_get(:@date_from)
    assert_nil service.send(:format_date, "bad-date")
  end
end
