# frozen_string_literal: true

require "openssl"
require "set"

module Graph
  class EntityNetworkService
    DEFAULT_NEIGHBOR_LIMIT = 50
    MIN_NEIGHBOR_LIMIT = 1
    MAX_NEIGHBOR_LIMIT = 200

    def initialize(entity:, date_from: nil, date_to: nil, neighbor_limit: DEFAULT_NEIGHBOR_LIMIT, include_individuals: false)
      @entity = entity
      @date_from = parse_date(date_from)
      @date_to = parse_date(date_to)
      @neighbor_limit = normalized_limit(neighbor_limit)
      @include_individuals = ActiveModel::Type::Boolean.new.cast(include_individuals)
    end

    def call
      merged = {}
      merge_rows!(merged, outgoing_rows, :outgoing)
      merge_rows!(merged, incoming_rows, :incoming)
      merged.delete(@entity.id)
      finalize_rows!(merged)

      ordered = merged.values.sort_by { |row| [ -row[:contract_count], -row[:total_value], row[:neighbor_id] ] }
      truncated = ordered.length > @neighbor_limit
      selected = ordered.first(@neighbor_limit)
      neighbors = Entity.where(id: selected.map { |row| row[:neighbor_id] }).index_by(&:id)
      selected_entity_ids = [ @entity.id ] + selected.map { |row| row[:neighbor_id] }
      entity_name_map = neighbors.transform_values(&:name).merge(@entity.id => @entity.name)

      nodes = build_nodes(selected, neighbors)
      edges = build_edges(selected, neighbors)
      edges.concat(build_peer_entity_edges(selected_entity_ids))

      individual_nodes, individual_edges = build_individual_layers(selected, entity_name_map) if @include_individuals
      individual_nodes ||= []
      individual_edges ||= []

      nodes.concat(individual_nodes)
      edges.concat(individual_edges)

      {
        nodes: nodes,
        edges: edges,
        meta: {
          focus_entity_id: @entity.id,
          focus_entity_type: node_type(@entity),
          includes_people: individual_nodes.any?,
          includes_tax_identifier: false,
          anonymization_mode: individual_nodes.any? ? "person_scoped_pseudonym" : "none",
          individual_node_count: individual_nodes.size,
          individual_edge_count: individual_edges.size,
          neighbor_limit: @neighbor_limit,
          total_neighbors: ordered.length,
          truncated: truncated,
          filters: {
            date_from: @date_from&.iso8601,
            date_to: @date_to&.iso8601
          }
        }
      }
    end

    private

    def outgoing_rows
      scope = Contract
        .joins(:contract_winners)
        .where(contracting_entity_id: @entity.id)
        .where.not(contract_winners: { entity_id: nil })
      scope = apply_date_filters(scope)

      scope.group("contract_winners.entity_id")
        .pluck(
          Arel.sql("contract_winners.entity_id"),
          Arel.sql("COUNT(DISTINCT contracts.id)"),
          Arel.sql("COALESCE(SUM(contracts.base_price), 0)"),
          Arel.sql("MAX(contracts.publication_date)")
        )
    end

    def incoming_rows
      scope = Contract
        .joins(:contract_winners)
        .where(contract_winners: { entity_id: @entity.id })
        .where.not(contracting_entity_id: nil)
      scope = apply_date_filters(scope)

      scope.group("contracts.contracting_entity_id")
        .pluck(
          Arel.sql("contracts.contracting_entity_id"),
          Arel.sql("COUNT(DISTINCT contracts.id)"),
          Arel.sql("COALESCE(SUM(contracts.base_price), 0)"),
          Arel.sql("MAX(contracts.publication_date)")
        )
    end

    def apply_date_filters(scope)
      scoped = scope
      scoped = scoped.where("contracts.publication_date >= ?", @date_from) if @date_from
      scoped = scoped.where("contracts.publication_date <= ?", @date_to) if @date_to
      scoped
    end

    def merge_rows!(merged, rows, direction)
      rows.each do |neighbor_id, contract_count, total_value, latest_publication_date|
        next if neighbor_id.nil?

        row = merged[neighbor_id] ||= {
          neighbor_id: neighbor_id,
          outgoing_contract_count: 0,
          incoming_contract_count: 0,
          outgoing_total_value: 0.0,
          incoming_total_value: 0.0,
          latest_publication_date: nil
        }

        if direction == :outgoing
          row[:outgoing_contract_count] += contract_count.to_i
          row[:outgoing_total_value] += total_value.to_f
        else
          row[:incoming_contract_count] += contract_count.to_i
          row[:incoming_total_value] += total_value.to_f
        end

        row[:latest_publication_date] = [ row[:latest_publication_date], latest_publication_date ].compact.max
      end
    end

    def finalize_rows!(merged)
      merged.each_value do |row|
        row[:contract_count] = row[:outgoing_contract_count] + row[:incoming_contract_count]
        row[:total_value] = row[:outgoing_total_value] + row[:incoming_total_value]
      end
    end

    def build_nodes(selected, neighbors)
      [ focus_node ] + selected.filter_map do |row|
        neighbor = neighbors[row[:neighbor_id]]
        next unless neighbor

        {
          id: node_id(neighbor.id),
          entity_id: neighbor.id,
          label: neighbor.name,
          node_type: node_type(neighbor),
          is_focus: false,
          metrics: {
            contract_count: row[:contract_count],
            total_value: row[:total_value].round(2),
            outgoing_contract_count: row[:outgoing_contract_count],
            incoming_contract_count: row[:incoming_contract_count],
            latest_publication_date: format_date(row[:latest_publication_date])
          }
        }
      end
    end

    def build_edges(selected, neighbors)
      selected.filter_map do |row|
        neighbor = neighbors[row[:neighbor_id]]
        next unless neighbor

        {
          id: "edge-#{@entity.id}-#{neighbor.id}",
          source: node_id(@entity.id),
          target: node_id(neighbor.id),
          edge_type: edge_type(row),
          metrics: {
            contract_count: row[:contract_count],
            total_value: row[:total_value].round(2),
            outgoing_contract_count: row[:outgoing_contract_count],
            outgoing_total_value: row[:outgoing_total_value].round(2),
            incoming_contract_count: row[:incoming_contract_count],
            incoming_total_value: row[:incoming_total_value].round(2),
            latest_publication_date: format_date(row[:latest_publication_date])
          }
        }
      end
    end

    def focus_node
      {
        id: node_id(@entity.id),
        entity_id: @entity.id,
        label: @entity.name,
        node_type: node_type(@entity),
        is_focus: true,
        metrics: {
          contract_count: @entity.contract_count.to_i,
          won_contract_count: @entity.won_contract_count.to_i
        }
      }
    end

    def edge_type(row)
      outgoing = row[:outgoing_contract_count].positive?
      incoming = row[:incoming_contract_count].positive?
      return "bidirectional_award" if outgoing && incoming
      return "awarded_by_focus" if outgoing

      "awarded_to_focus"
    end

    def node_id(entity_id)
      "entity-#{entity_id}"
    end

    def node_type(entity)
      entity.is_public_body? ? "public_body" : "company"
    end

    def build_individual_layers(selected, entity_name_map)
      entity_ids = [ @entity.id ] + selected.map { |row| row[:neighbor_id] }
      records = individual_records(entity_ids)

      grouped_nodes = records.group_by { |record| individual_node_id(record[:pseudonym_seed]) }
      nodes = grouped_nodes.map { |individual_id, grouped_records| build_individual_node(individual_id, grouped_records, entity_name_map) }
      edges = build_individual_edges(records)
      enrich_individual_nodes_with_contract_metrics!(nodes, grouped_nodes, entity_ids)

      [ nodes, edges ]
    end

    def individual_records(entity_ids)
      ids = entity_ids.compact.uniq
      return [] if ids.empty?

      role_records = EntityPersonRole.active.includes(:person).where(entity_id: ids).map do |role|
        {
          entity_id: role.entity_id,
          role_type: role.role_type,
          role_label: role.role,
          name: role.name.to_s,
          source_name: role.source_name,
          active: role.active?,
          start_date: role.start_date,
          end_date: role.end_date,
          pseudonym_seed: role.person&.tax_identifier.present? ? "nif-#{role.person.tax_identifier}" : "person-#{role.person_id}"
        }
      end

      role_entity_ids = role_records.map { |record| record[:entity_id] }.uniq
      legacy_entity_ids = ids - role_entity_ids

      legacy_records = CompanyDirector.where(entity_id: legacy_entity_ids).map do |director|
        {
          entity_id: director.entity_id,
          role_type: "director",
          role_label: director.role.presence || "Director",
          name: director.name.to_s,
          source_name: "Legacy Directors",
          active: true,
          start_date: nil,
          end_date: nil,
          pseudonym_seed: "company-director-#{director.id}"
        }
      end

      role_records + legacy_records
    end

    def build_peer_entity_edges(entity_ids)
      ids = entity_ids.compact.uniq
      return [] if ids.length < 2

      scope = Contract
        .joins(:contract_winners)
        .where(contracting_entity_id: ids)
        .where(contract_winners: { entity_id: ids })
        .where("contracts.contracting_entity_id != contract_winners.entity_id")
      scope = apply_date_filters(scope)

      scope.group("contracts.contracting_entity_id", "contract_winners.entity_id")
        .pluck(
          Arel.sql("contracts.contracting_entity_id"),
          Arel.sql("contract_winners.entity_id"),
          Arel.sql("COUNT(DISTINCT contracts.id)"),
          Arel.sql("COALESCE(SUM(contracts.base_price), 0)"),
          Arel.sql("MAX(contracts.publication_date)")
        )
        .filter_map { |source_id, target_id, contract_count, total_value, latest_publication_date|
          next if source_id.nil? || target_id.nil?
          next if source_id == @entity.id || target_id == @entity.id

          {
            id: "edge-peer-#{source_id}-#{target_id}",
            source: node_id(source_id),
            target: node_id(target_id),
            edge_type: "peer_award_link",
            metrics: {
              contract_count: contract_count.to_i,
              total_value: total_value.to_f.round(2),
              outgoing_contract_count: contract_count.to_i,
              outgoing_total_value: total_value.to_f.round(2),
              incoming_contract_count: 0,
              incoming_total_value: 0.0,
              latest_publication_date: format_date(latest_publication_date)
            }
          }
        }
    end

    def build_individual_node(individual_id, grouped_records, entity_name_map)
      first_record = grouped_records.first
      connected_entity_ids = grouped_records.map { |record| record[:entity_id] }.uniq

      {
        id: individual_id,
        entity_id: first_record[:entity_id],
        label: pseudonymised_individual_label(first_record[:name], individual_id),
        node_type: "individual",
        is_focus: false,
        metrics: {
          contract_count: 0,
          total_value: 0.0,
          outgoing_contract_count: 0,
          incoming_contract_count: 0,
          role_type: grouped_records.map { |record| record[:role_type] }.uniq.join(", "),
          role_label: grouped_records.map { |record| record[:role_label] }.uniq.join(", "),
          source_name: grouped_records.map { |record| record[:source_name] }.uniq.join(", "),
          connected_entity_ids: connected_entity_ids,
          connected_entity_labels: format_connected_entity_labels(connected_entity_ids, entity_name_map),
          connected_entity_count: connected_entity_ids.size,
          involved_contract_count: 0,
          involved_total_value: 0.0,
          risk_total_score: 0,
          risk_flagged_contract_count: 0,
          risk_severity_breakdown: default_risk_breakdown,
          active: grouped_records.any? { |record| record[:active] },
          start_date: format_date(grouped_records.map { |record| record[:start_date] }.compact.min),
          end_date: format_date(grouped_records.map { |record| record[:end_date] }.compact.max)
        }
      }
    end

    def build_individual_edges(records)
      grouped_edges = records.group_by { |record| [ record[:entity_id], individual_node_id(record[:pseudonym_seed]) ] }

      grouped_edges.map { |(entity_id, individual_id), grouped_records|
        {
          id: "edge-role-#{entity_id}-#{individual_id}",
          source: node_id(entity_id),
          target: individual_id,
          edge_type: "entity_role_link",
          metrics: {
            contract_count: 0,
            total_value: 0.0,
            outgoing_contract_count: 0,
            outgoing_total_value: 0.0,
            incoming_contract_count: 0,
            incoming_total_value: 0.0,
            role_type: grouped_records.map { |record| record[:role_type] }.uniq.join(", "),
            role_label: grouped_records.map { |record| record[:role_label] }.uniq.join(", "),
            source_name: grouped_records.map { |record| record[:source_name] }.uniq.join(", "),
            active: grouped_records.any? { |record| record[:active] },
            start_date: format_date(grouped_records.map { |record| record[:start_date] }.compact.min),
            end_date: format_date(grouped_records.map { |record| record[:end_date] }.compact.max),
            latest_publication_date: nil
          }
        }
      }
    end

    def enrich_individual_nodes_with_contract_metrics!(nodes, grouped_nodes, entity_ids)
      return if nodes.empty?

      entity_to_contract_ids, contract_values = entity_contract_mappings(entity_ids)
      return if contract_values.empty?

      risk_by_contract = contract_risk_mappings(contract_values.keys)

      nodes.each do |node|
        individual_records = grouped_nodes[node[:id]] || []
        connected_entity_ids = if individual_records.any?
          individual_records.map { |record| record[:entity_id] }.uniq
        else
          Array(node.dig(:metrics, :connected_entity_ids))
        end

        involved_contract_ids = connected_entity_ids.each_with_object(Set.new) do |entity_id, memo|
          memo.merge(entity_to_contract_ids[entity_id])
        end

        involved_total_value = 0.0
        risk_total_score = 0
        risk_flagged_contract_count = 0
        risk_severity_breakdown = default_risk_breakdown

        involved_contract_ids.each do |contract_id|
          involved_total_value += contract_values.fetch(contract_id, 0.0)

          risk_data = risk_by_contract[contract_id]
          next unless risk_data

          risk_flagged_contract_count += 1
          risk_total_score += risk_data[:score]
          risk_data[:severity_breakdown].each do |severity, count|
            risk_severity_breakdown[severity] += count
          end
        end

        node[:metrics][:connected_entity_count] = connected_entity_ids.size
        node[:metrics][:involved_contract_count] = involved_contract_ids.size
        node[:metrics][:involved_total_value] = involved_total_value.round(2)
        node[:metrics][:risk_total_score] = risk_total_score
        node[:metrics][:risk_flagged_contract_count] = risk_flagged_contract_count
        node[:metrics][:risk_severity_breakdown] = risk_severity_breakdown
      end
    end

    def entity_contract_mappings(entity_ids)
      ids = entity_ids.compact.uniq
      return [Hash.new { |h, k| h[k] = Set.new }, {}] if ids.empty?

      scope = Contract
        .left_joins(:contract_winners)
        .where("contracts.contracting_entity_id IN (:ids) OR contract_winners.entity_id IN (:ids)", ids: ids)
        .distinct
      scope = apply_date_filters(scope)

      contracts = scope.select("contracts.id", "contracts.contracting_entity_id", "contracts.base_price").to_a
      contract_ids = contracts.map(&:id)

      entity_to_contract_ids = Hash.new { |h, k| h[k] = Set.new }
      contracts.each do |contract|
        contracting_entity_id = contract.contracting_entity_id
        next unless ids.include?(contracting_entity_id)

        entity_to_contract_ids[contracting_entity_id] << contract.id
      end

      ContractWinner.where(contract_id: contract_ids, entity_id: ids).pluck(:contract_id, :entity_id).each do |contract_id, entity_id|
        entity_to_contract_ids[entity_id] << contract_id
      end

      contract_values = contracts.each_with_object({}) do |contract, memo|
        memo[contract.id] = contract.base_price.to_f
      end

      [entity_to_contract_ids, contract_values]
    end

    def contract_risk_mappings(contract_ids)
      ids = Array(contract_ids)
      return {} if ids.empty?

      risk_by_contract = {}

      Flag.where(contract_id: ids).pluck(:contract_id, :severity, :score).each do |contract_id, severity, score|
        risk_by_contract[contract_id] ||= {
          score: 0,
          severity_breakdown: default_risk_breakdown
        }

        risk_by_contract[contract_id][:score] += score.to_i
        normalized = severity.to_s.downcase
        if risk_by_contract[contract_id][:severity_breakdown].key?(normalized)
          risk_by_contract[contract_id][:severity_breakdown][normalized] += 1
        end
      end

      risk_by_contract
    end

    def default_risk_breakdown
      {
        "critical" => 0,
        "high" => 0,
        "medium" => 0,
        "low" => 0
      }
    end

    def format_connected_entity_labels(entity_ids, entity_name_map)
      entity_ids.map { |entity_id| entity_name_map[entity_id] }.compact
    end

    def individual_node_id(seed)
      token = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, seed.to_s)[0, 10]
      "individual-#{token}"
    end

    def pseudonymised_individual_label(name, node_id_value)
      initials = name.to_s.split(/\s+/).filter_map { |word| word[0]&.upcase if word.length > 1 }.first(2).join(".")
      initials = "?" if initials.blank?
      token = node_id_value.delete_prefix("individual-")[0, 4]

      "#{initials}. [P-#{token}]"
    end

    def normalized_limit(value)
      parsed = Integer(value, exception: false)
      return DEFAULT_NEIGHBOR_LIMIT unless parsed

      [ [ parsed, MIN_NEIGHBOR_LIMIT ].max, MAX_NEIGHBOR_LIMIT ].min
    end

    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value)
    rescue ArgumentError
      nil
    end

    def format_date(value)
      return nil if value.blank?
      return value.iso8601 if value.respond_to?(:iso8601)

      Date.iso8601(value.to_s).iso8601
    rescue ArgumentError
      nil
    end
  end
end
