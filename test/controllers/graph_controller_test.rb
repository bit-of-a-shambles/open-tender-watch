# frozen_string_literal: true

require "test_helper"

class GraphControllerTest < ActionDispatch::IntegrationTest
  test "search endpoint returns entity matches" do
    get graph_search_entities_url, params: { q: "Lisboa" }

    assert_response :success
    assert_equal "application/json", response.media_type

    data = JSON.parse(response.body)
    match = data.fetch("results").find { |result| result["id"] == entities(:one).id }
    assert_not_nil match
    assert_equal "public_body", match["node_type"]
    assert_equal "entity-#{entities(:one).id}", match["node_id"]
  end

  test "search endpoint keeps individual results hidden for public users" do
    EntityPersonRole.create!(
      entity: entities(:one),
      person: people(:joao),
      role_type: "director",
      role_label: "Director",
      source_name: "Registo Comercial",
      active: true
    )

    get graph_search_entities_url, params: { q: people(:joao).tax_identifier }

    assert_response :success
    data = JSON.parse(response.body)
    refute data.fetch("results").any? { |result| result["node_type"] == "individual" }
  end

  test "search endpoint returns individual NIF result for authenticated users" do
    EntityPersonRole.create!(
      entity: entities(:one),
      person: people(:joao),
      role_type: "director",
      role_label: "Director",
      source_name: "Registo Comercial",
      active: true
    )
    EntityPersonRole.create!(
      entity: entities(:two),
      person: people(:joao),
      role_type: "officer",
      role_label: "Fiscal Único",
      source_name: "Registo Comercial",
      active: true
    )

    post access_token_url, params: { token: access_tokens(:one).token }
    get graph_search_entities_url, params: { q: people(:joao).tax_identifier }

    assert_response :success
    data = JSON.parse(response.body)
    individual = data.fetch("results").find { |result| result["node_type"] == "individual" }
    assert_not_nil individual

    assert individual.fetch("node_id").start_with?("individual-")
    assert_equal 2, individual.fetch("entity_count")
    assert_equal [ entities(:one).id, entities(:two).id ].sort, individual.fetch("entity_ids").sort
    refute_includes individual.fetch("name"), people(:joao).name
    refute_includes individual.fetch("name"), people(:joao).tax_identifier
    refute_includes response.body, people(:joao).tax_identifier
  end

  test "entity network returns JSON graph payload" do
    get entity_network_graph_url(entity_id: entities(:one).id)

    assert_response :success
    assert_equal "application/json", response.media_type

    data = JSON.parse(response.body)
    assert data.key?("nodes")
    assert data.key?("edges")
    assert data.key?("meta")
    assert_equal false, data.dig("meta", "includes_people")
    assert_equal false, data.dig("meta", "includes_tax_identifier")
  end

  test "entity network payload does not expose tax identifiers" do
    get entity_network_graph_url(entity_id: entities(:one).id)

    assert_response :success
    refute_includes response.body, entities(:one).tax_identifier
    refute_includes response.body, entities(:two).tax_identifier

    data = JSON.parse(response.body)
    data.fetch("nodes").each do |node|
      refute node.key?("tax_identifier")
    end
    data.fetch("edges").each do |edge|
      refute edge.key?("tax_identifier")
    end
  end

  test "entity network honors date filter and limit params" do
    focus = Entity.create!(
      name: "Graph Focus",
      tax_identifier: "520000111",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    old_neighbor = Entity.create!(
      name: "Graph Old Neighbor",
      tax_identifier: "520000112",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    recent_neighbor_a = Entity.create!(
      name: "Graph Recent Neighbor A",
      tax_identifier: "520000113",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    recent_neighbor_b = Entity.create!(
      name: "Graph Recent Neighbor B",
      tax_identifier: "520000114",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    old_contract = Contract.create!(
      external_id: "graph-controller-old",
      country_code: "PT",
      object: "Graph old contract",
      contracting_entity: focus,
      publication_date: Date.new(2020, 1, 10),
      celebration_date: Date.new(2020, 1, 12),
      base_price: 10
    )
    ContractWinner.create!(contract: old_contract, entity: old_neighbor, price_share: 10)

    recent_contract_a = Contract.create!(
      external_id: "graph-controller-recent-a",
      country_code: "PT",
      object: "Graph recent contract A",
      contracting_entity: focus,
      publication_date: Date.new(2026, 2, 10),
      celebration_date: Date.new(2026, 2, 12),
      base_price: 200
    )
    ContractWinner.create!(contract: recent_contract_a, entity: recent_neighbor_a, price_share: 200)

    recent_contract_b = Contract.create!(
      external_id: "graph-controller-recent-b",
      country_code: "PT",
      object: "Graph recent contract B",
      contracting_entity: focus,
      publication_date: Date.new(2026, 2, 11),
      celebration_date: Date.new(2026, 2, 13),
      base_price: 100
    )
    ContractWinner.create!(contract: recent_contract_b, entity: recent_neighbor_b, price_share: 100)

    get entity_network_graph_url(entity_id: focus.id), params: { date_from: "2026-01-01", limit: 1 }

    assert_response :success

    data = JSON.parse(response.body)
    labels = data.fetch("nodes").map { |node| node.fetch("label") }

    assert_equal 1, data.dig("meta", "neighbor_limit")
    assert_equal true, data.dig("meta", "truncated")
    assert_equal 2, labels.length
    assert_includes labels, focus.name
    assert_includes labels, recent_neighbor_a.name
    assert_not_includes labels, recent_neighbor_b.name
    assert_not_includes labels, old_neighbor.name
  end

  test "entity network ignores individual mode in public access" do
    EntityPersonRole.create!(
      entity: entities(:one),
      person: people(:joao),
      role_type: "director",
      role_label: "Director",
      source_name: "Registo Comercial",
      active: true
    )

    get entity_network_graph_url(entity_id: entities(:one).id), params: { include_individuals: true }

    assert_response :success
    data = JSON.parse(response.body)
    assert_equal false, data.dig("meta", "includes_people")
    assert_equal false, data.dig("meta", "includes_tax_identifier")
    refute data.fetch("nodes").any? { |node| node["node_type"] == "individual" }
    refute data.fetch("edges").any? { |edge| edge["edge_type"] == "entity_role_link" }
    refute_includes response.body, people(:joao).name
    refute_includes response.body, people(:joao).tax_identifier
  end

  test "entity network includes anonymized individual nodes for authenticated users" do
    EntityPersonRole.create!(
      entity: entities(:one),
      person: people(:joao),
      role_type: "director",
      role_label: "Director",
      source_name: "Registo Comercial",
      active: true
    )

    post access_token_url, params: { token: access_tokens(:one).token }

    get entity_network_graph_url(entity_id: entities(:one).id), params: { include_individuals: true }

    assert_response :success
    data = JSON.parse(response.body)

    assert_equal true, data.dig("meta", "includes_people")
    assert_equal false, data.dig("meta", "includes_tax_identifier")
    assert data.fetch("nodes").any? { |node| node["node_type"] == "individual" }
    assert data.fetch("edges").any? { |edge| edge["edge_type"] == "entity_role_link" }
    refute_includes response.body, people(:joao).name
    refute_includes response.body, people(:joao).tax_identifier
  end

  test "entity network individual mode does not mutate scraped people data" do
    post access_token_url, params: { token: access_tokens(:one).token }

    assert_no_changes -> { Person.count } do
      assert_no_changes -> { EntityPersonRole.count } do
        assert_no_changes -> { CompanyDirector.count } do
          get entity_network_graph_url(entity_id: entities(:one).id), params: { include_individuals: true }
          assert_response :success
        end
      end
    end
  end

  test "network map returns global payload with flagged summary" do
    authority = Entity.create!(
      name: "Network Map Authority",
      tax_identifier: "560000101",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    supplier = Entity.create!(
      name: "Network Map Supplier",
      tax_identifier: "560000102",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    flagged_contract = Contract.create!(
      external_id: "network-map-flagged",
      country_code: "PT",
      object: "Flagged contract",
      contracting_entity: authority,
      publication_date: Date.new(2030, 1, 10),
      celebration_date: Date.new(2030, 1, 11),
      base_price: 500
    )
    ContractWinner.create!(contract: flagged_contract, entity: supplier, price_share: 500)
    Flag.create!(
      contract: flagged_contract,
      flag_type: "A1_REPEAT_DIRECT_AWARD",
      severity: "high",
      score: 7,
      fired_at: Time.current
    )

    get network_map_graph_url, params: { date_from: "2030-01-01", date_to: "2030-12-31", limit: 30 }

    assert_response :success
    assert_equal "application/json", response.media_type

    data = JSON.parse(response.body)
    assert data.key?("nodes")
    assert data.key?("edges")
    assert data.key?("meta")
    assert_equal false, data.dig("meta", "includes_tax_identifier")
    assert_operator data.dig("meta", "summary", "total_flagged_value"), :>=, 500.0
  end

  test "network map honors boolean node type filters" do
    get network_map_graph_url, params: {
      include_public_bodies: "false",
      include_companies: "true",
      limit: 30
    }

    assert_response :success
    data = JSON.parse(response.body)
    assert_equal false, data.dig("meta", "filters", "include_public_bodies")
    assert_equal true, data.dig("meta", "filters", "include_companies")
  end

  test "network map forwards isolate network toggle" do
    get network_map_graph_url, params: {
      isolate_network: "true",
      must_include_entity_ids: [ entities(:one).id ],
      limit: 30
    }

    assert_response :success
    data = JSON.parse(response.body)
    assert_equal true, data.dig("meta", "filters", "isolate_network")
  end

  test "network map auto-enables isolate mode when forced entities are provided" do
    get network_map_graph_url, params: {
      must_include_entity_ids: [ entities(:one).id ],
      limit: 30
    }

    assert_response :success
    data = JSON.parse(response.body)
    assert_equal true, data.dig("meta", "filters", "isolate_network")
  end

  test "network map allows explicitly disabling isolate mode" do
    get network_map_graph_url, params: {
      isolate_network: "false",
      must_include_entity_ids: [ entities(:one).id ],
      limit: 30
    }

    assert_response :success
    data = JSON.parse(response.body)
    assert_equal false, data.dig("meta", "filters", "isolate_network")
  end

  test "network map emits telemetry notification" do
    authority = Entity.create!(
      name: "Telemetry Authority",
      tax_identifier: "560900101",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    supplier = Entity.create!(
      name: "Telemetry Supplier",
      tax_identifier: "560900102",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    contract = Contract.create!(
      external_id: "network-map-telemetry",
      country_code: "PT",
      object: "Telemetry contract",
      contracting_entity: authority,
      publication_date: Date.new(2033, 6, 10),
      celebration_date: Date.new(2033, 6, 11),
      base_price: 140
    )
    ContractWinner.create!(contract: contract, entity: supplier, price_share: 140)

    events = []
    callback = ->(*args) { events << ActiveSupport::Notifications::Event.new(*args) }

    ActiveSupport::Notifications.subscribed(callback, "graph.network_map.request") do
      get network_map_graph_url, params: { date_from: "2033-01-01", date_to: "2033-12-31", limit: 30 }
    end

    assert_response :success
    assert_equal 1, events.size

    payload = events.first.payload
    assert payload.key?(:cache_key)
    assert_includes [ true, false ], payload[:cache_hit]
    assert_operator payload[:request_ms], :>=, 0.0
    assert_equal "public", payload[:access_level]
  end

  test "network map keeps individuals hidden for public users while exposing connected-individual summary" do
    authority = Entity.create!(
      name: "Public Network Authority",
      tax_identifier: "560000201",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    supplier = Entity.create!(
      name: "Public Network Supplier",
      tax_identifier: "560000202",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    contract = Contract.create!(
      external_id: "network-map-public",
      country_code: "PT",
      object: "Public mode contract",
      contracting_entity: authority,
      publication_date: Date.new(2031, 2, 10),
      celebration_date: Date.new(2031, 2, 11),
      base_price: 150
    )
    ContractWinner.create!(contract: contract, entity: supplier, price_share: 150)

    EntityPersonRole.create!(
      entity: supplier,
      person: people(:joao),
      role_type: "director",
      role_label: "Director",
      source_name: "Registo Comercial",
      active: true
    )

    get network_map_graph_url, params: {
      date_from: "2031-01-01",
      date_to: "2031-12-31",
      include_individuals: true,
      limit: 30
    }

    assert_response :success
    data = JSON.parse(response.body)
    assert_equal false, data.dig("meta", "includes_people")
    assert_operator data.dig("meta", "summary", "connected_individual_count"), :>=, 1
    refute data.fetch("nodes").any? { |node| node["node_type"] == "individual" }
  end

  test "network map includes pseudonymized individual nodes for authenticated users" do
    authority = Entity.create!(
      name: "Auth Network Authority",
      tax_identifier: "560000301",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    supplier = Entity.create!(
      name: "Auth Network Supplier",
      tax_identifier: "560000302",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )

    contract = Contract.create!(
      external_id: "network-map-auth",
      country_code: "PT",
      object: "Authenticated mode contract",
      contracting_entity: authority,
      publication_date: Date.new(2032, 3, 10),
      celebration_date: Date.new(2032, 3, 11),
      base_price: 180
    )
    ContractWinner.create!(contract: contract, entity: supplier, price_share: 180)

    EntityPersonRole.create!(
      entity: supplier,
      person: people(:maria),
      role_type: "officer",
      role_label: "Fiscal Único",
      source_name: "Registo Comercial",
      active: true
    )

    post access_token_url, params: { token: access_tokens(:one).token }

    get network_map_graph_url, params: {
      date_from: "2032-01-01",
      date_to: "2032-12-31",
      include_individuals: true,
      limit: 30
    }

    assert_response :success
    data = JSON.parse(response.body)
    assert_equal true, data.dig("meta", "includes_people")
    assert data.fetch("nodes").any? { |node| node["node_type"] == "individual" }
    refute_includes response.body, people(:maria).name
    refute_includes response.body, people(:maria).tax_identifier
  end
end
