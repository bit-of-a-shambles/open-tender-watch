# frozen_string_literal: true

require "openssl"
require "set"

module Graph
  class NetworkMapService
    DEFAULT_NODE_LIMIT = 80
    MIN_NODE_LIMIT = 20
    MAX_NODE_LIMIT = 400
    INDIVIDUAL_ROLE_LIMIT_PER_ENTITY = 20
    INDIVIDUAL_CONTRACT_ENRICHMENT_ENTITY_LIMIT = 50
    ISOLATE_RECURSIVE_DEPTH = 1
    PREAGGREGATED_AVAILABILITY_CACHE_KEY = "graph/network_map/preaggregated_edges_available"

    def initialize(date_from: nil, date_to: nil, node_limit: DEFAULT_NODE_LIMIT, include_individuals: false,
                   include_public_bodies: true, include_companies: true, data_source_ids: nil,
                   must_include_entity_ids: nil, isolate_network: false, instrumentation: nil)
      @date_from = parse_date(date_from)
      @date_to = parse_date(date_to)
      @node_limit = normalized_limit(node_limit)
      @include_individuals = ActiveModel::Type::Boolean.new.cast(include_individuals)
      @include_public_bodies = ActiveModel::Type::Boolean.new.cast(include_public_bodies)
      @include_companies = ActiveModel::Type::Boolean.new.cast(include_companies)
      @data_source_ids = parse_data_source_ids(data_source_ids)
      @must_include_entity_ids = parse_must_include_entity_ids(must_include_entity_ids)
      @isolate_network = ActiveModel::Type::Boolean.new.cast(isolate_network)
      @instrumentation = instrumentation.is_a?(Hash) ? instrumentation : nil
      @instrumentation[:timings_ms] ||= {} if @instrumentation
      @edge_source = nil
    end

    def call
      call_started_at = monotonic_now

      return empty_payload if !@include_public_bodies && !@include_companies

      selection = if preaggregated_fast_path_applicable?
        preaggregated_fast_selection
      else
        regular_selection
      end

      return empty_payload if selection[:selected_node_ids].empty?

      entities = measure_timing(:entity_lookup) { Entity.where(id: selection[:selected_node_ids]).index_by(&:id) }
      entity_name_map = entities.transform_values(&:name)

      nodes = measure_timing(:entity_nodes_build) { build_nodes(selection[:selected_node_ids], entities, selection[:selected_node_scores]) }
      edges = measure_timing(:entity_edges_build) { build_edges(selection[:selected_edge_rows]) }

      individual_nodes, individual_edges, shared_individual_edges, connected_individual_count =
        measure_timing(:individual_layers) { build_individual_layers(selection[:selected_node_ids], entity_name_map) }

      nodes.concat(individual_nodes)
      edges.concat(individual_edges)
      edges.concat(shared_individual_edges)

      payload = {
        nodes: nodes,
        edges: edges,
        meta: {
          includes_people: individual_nodes.any?,
          includes_tax_identifier: false,
          anonymization_mode: individual_nodes.any? ? "person_scoped_pseudonym" : "none",
          node_limit: @node_limit,
          total_nodes: selection[:total_nodes],
          total_edges: selection[:all_edge_count] + shared_individual_edges.size,
          truncated: selection[:truncated],
          filters: {
            date_from: @date_from&.iso8601,
            date_to: @date_to&.iso8601,
            include_public_bodies: @include_public_bodies,
            include_companies: @include_companies,
            isolate_network: @isolate_network
          },
          summary: summary_metrics(selection[:selected_edge_rows], connected_individual_count)
        }
      }

      annotate_instrumentation(payload, edge_row_count: selection[:all_edge_count], total_ms: elapsed_ms(call_started_at))
      payload
    end

    private

    def regular_selection
      edge_rows = measure_timing(:edge_aggregation) { aggregated_edge_rows }
      return empty_selection if edge_rows.empty?

      all_node_scores = {}
      selected_edge_rows = []
      selected_node_scores = {}
      selected_node_ids = []

      measure_timing(:node_selection) do
        all_node_scores = build_node_scores(edge_rows)
        ordered_node_ids = all_node_scores
          .sort_by { |entity_id, stats| [ -stats[:contract_count], -stats[:total_value], entity_id ] }
          .first(@node_limit)
          .map(&:first)

        ordered_node_ids = expand_with_forced_entities(ordered_node_ids)

        selected_node_ids_set = ordered_node_ids.to_set
        selected_edge_rows = edge_rows.select do |row|
          selected_node_ids_set.include?(row[:source_id]) && selected_node_ids_set.include?(row[:target_id])
        end

        selected_node_scores = build_node_scores(selected_edge_rows)
        forced_entity_ids = @must_include_entity_ids.to_set
        selected_node_ids = ordered_node_ids.select do |entity_id|
          selected_node_scores.key?(entity_id) || forced_entity_ids.include?(entity_id)
        end
      end

      {
        selected_edge_rows: selected_edge_rows,
        selected_node_scores: selected_node_scores,
        selected_node_ids: selected_node_ids,
        total_nodes: all_node_scores.size,
        all_edge_count: edge_rows.size,
        truncated: all_node_scores.size > @node_limit
      }
    end

    def preaggregated_fast_selection
      @edge_source = "preaggregated_fast"
      scope = GraphEdgeDailySummary.all
      scope = apply_preaggregated_node_type_filters(scope)

      top_node_ids = []
      total_nodes = 0

      measure_timing(:node_selection) do
        top_node_ids, total_nodes = preaggregated_top_node_ids_and_total_count(scope)
      end

      selected_edge_rows = measure_timing(:edge_aggregation) do
        preaggregated_selected_edge_rows(scope, top_node_ids)
      end
      selected_node_scores = build_node_scores(selected_edge_rows)
      selected_node_ids = top_node_ids.select { |entity_id| selected_node_scores.key?(entity_id) }

      {
        selected_edge_rows: selected_edge_rows,
        selected_node_scores: selected_node_scores,
        selected_node_ids: selected_node_ids,
        total_nodes: total_nodes,
        all_edge_count: selected_edge_rows.size,
        truncated: total_nodes > @node_limit
      }
    end

    def preaggregated_fast_path_applicable?
      preaggregated_edges_available? &&
        @date_from.nil? &&
        @date_to.nil? &&
        @data_source_ids.blank? &&
        !@isolate_network &&
        @must_include_entity_ids.blank?
    end

    def preaggregated_top_node_ids_and_total_count(scope)
      edges_sql = scope
        .reselect("source_entity_id", "target_entity_id", "contract_count", "total_value")
        .to_sql

      rows = ActiveRecord::Base.connection.select_rows(<<~SQL)
        WITH
          filtered_edges AS (
            SELECT source_entity_id, target_entity_id, contract_count, total_value
            FROM (#{edges_sql}) AS base_edges
            WHERE source_entity_id IS NOT NULL AND target_entity_id IS NOT NULL
          ),
          node_contribs AS (
            SELECT source_entity_id AS node_id, contract_count, total_value
            FROM filtered_edges
            UNION ALL
            SELECT target_entity_id AS node_id, contract_count, total_value
            FROM filtered_edges
          ),
          node_scores AS (
            SELECT
              node_id,
              SUM(contract_count) AS contract_count,
              SUM(total_value) AS total_value
            FROM node_contribs
            GROUP BY node_id
          ),
          ranked_nodes AS (
            SELECT
              node_id,
              COUNT(*) OVER () AS total_nodes
            FROM node_scores
            ORDER BY contract_count DESC, total_value DESC, node_id ASC
            LIMIT #{@node_limit}
          )
        SELECT node_id, total_nodes
        FROM ranked_nodes
      SQL

      node_ids = rows.filter_map { |row| Integer(row[0], exception: false) }
      total_nodes = rows.first ? rows.first[1].to_i : 0

      [ node_ids, total_nodes ]
    end

    def preaggregated_selected_edge_rows(scope, node_ids)
      ids = Array(node_ids).compact.uniq
      return [] if ids.empty?

      scope
        .where(source_entity_id: ids, target_entity_id: ids)
        .group(:source_entity_id, :target_entity_id)
        .pluck(
          Arel.sql("source_entity_id"),
          Arel.sql("target_entity_id"),
          Arel.sql("COALESCE(SUM(contract_count), 0)"),
          Arel.sql("COALESCE(SUM(total_value), 0)"),
          Arel.sql("COALESCE(SUM(flagged_contract_count), 0)"),
          Arel.sql("COALESCE(SUM(flagged_total_value), 0)"),
          Arel.sql("COALESCE(SUM(risk_total_score), 0)"),
          Arel.sql("MAX(publication_date)")
        ).filter_map do |source_id, target_id, contract_count, total_value, flagged_contract_count, flagged_total_value, risk_total_score, latest_publication_date|
          next if source_id.nil? || target_id.nil? || source_id == target_id

          {
            source_id: source_id,
            target_id: target_id,
            contract_count: contract_count.to_i,
            total_value: total_value.to_f,
            flagged_contract_count: flagged_contract_count.to_i,
            flagged_total_value: flagged_total_value.to_f,
            risk_total_score: risk_total_score.to_i,
            latest_publication_date: latest_publication_date
          }
        end
    end

    def empty_selection
      {
        selected_edge_rows: [],
        selected_node_scores: {},
        selected_node_ids: [],
        total_nodes: 0,
        all_edge_count: 0,
        truncated: false
      }
    end

    def aggregated_edge_rows
      if preaggregated_edges_available?
        @edge_source = "preaggregated"
        return preaggregated_edge_rows
      end

      @edge_source = "live"
      live_aggregated_edge_rows
    end

    def annotate_instrumentation(payload, edge_row_count:, total_ms:)
      return unless @instrumentation

      @instrumentation[:edge_source] = @edge_source || "none"
      @instrumentation[:used_preaggregated_edges] = @edge_source.to_s.start_with?("preaggregated")
      @instrumentation[:include_individuals] = @include_individuals
      @instrumentation[:edge_row_count] = edge_row_count
      @instrumentation[:node_count] = payload[:nodes].size
      @instrumentation[:edge_count] = payload[:edges].size
      @instrumentation[:timings_ms][:total] = total_ms
    end

    def measure_timing(key)
      return yield unless @instrumentation

      started_at = monotonic_now
      result = yield
      @instrumentation[:timings_ms][key] = elapsed_ms(started_at)
      result
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      ((monotonic_now - started_at) * 1000.0).round(1)
    end

    def preaggregated_edge_rows
      scope = GraphEdgeDailySummary.all
      scope = apply_preaggregated_date_filters(scope)
      scope = apply_preaggregated_node_type_filters(scope)
      scope = apply_preaggregated_data_source_filter(scope)
      scope = apply_preaggregated_isolate_filter(scope)

      scope
        .group(:source_entity_id, :target_entity_id)
        .pluck(
          Arel.sql("source_entity_id"),
          Arel.sql("target_entity_id"),
          Arel.sql("COALESCE(SUM(contract_count), 0)"),
          Arel.sql("COALESCE(SUM(total_value), 0)"),
          Arel.sql("COALESCE(SUM(flagged_contract_count), 0)"),
          Arel.sql("COALESCE(SUM(flagged_total_value), 0)"),
          Arel.sql("COALESCE(SUM(risk_total_score), 0)"),
          Arel.sql("MAX(publication_date)")
        ).filter_map do |source_id, target_id, contract_count, total_value, flagged_contract_count, flagged_total_value, risk_total_score, latest_publication_date|
          next if source_id.nil? || target_id.nil? || source_id == target_id

          {
            source_id: source_id,
            target_id: target_id,
            contract_count: contract_count.to_i,
            total_value: total_value.to_f,
            flagged_contract_count: flagged_contract_count.to_i,
            flagged_total_value: flagged_total_value.to_f,
            risk_total_score: risk_total_score.to_i,
            latest_publication_date: latest_publication_date
          }
        end
    end

    def preaggregated_edges_available?
      return false unless GraphEdgeDailySummary.table_exists?

      Rails.cache.fetch(PREAGGREGATED_AVAILABILITY_CACHE_KEY, expires_in: 5.minutes) do
        GraphEdgeDailySummary.exists?
      end
    rescue ActiveRecord::StatementInvalid
      false
    end

    def live_aggregated_edge_rows
      scope = Contract
        .joins(:contract_winners)
        .joins(<<~SQL.squish)
          LEFT JOIN (
            SELECT flags.contract_id, SUM(flags.score) AS total_score
            FROM flags
            GROUP BY flags.contract_id
          ) AS flag_totals ON flag_totals.contract_id = contracts.id
        SQL
        .where.not(contracting_entity_id: nil)
        .where.not(contract_winners: { entity_id: nil })
      scope = apply_date_filters(scope)
      scope = apply_node_type_filters(scope)
      scope = apply_data_source_filter(scope)
      scope = apply_isolate_filter(scope)

      edge_rows = scope
        .group("contracts.contracting_entity_id", "contract_winners.entity_id")
        .pluck(
          Arel.sql("contracts.contracting_entity_id"),
          Arel.sql("contract_winners.entity_id"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(contracts.base_price), 0)"),
          Arel.sql("COALESCE(SUM(CASE WHEN flag_totals.contract_id IS NOT NULL THEN 1 ELSE 0 END), 0)"),
          Arel.sql("COALESCE(SUM(CASE WHEN flag_totals.contract_id IS NOT NULL THEN contracts.base_price ELSE 0 END), 0)"),
          Arel.sql("COALESCE(SUM(flag_totals.total_score), 0)"),
          Arel.sql("MAX(contracts.publication_date)")
        ).filter_map do |source_id, target_id, contract_count, total_value, flagged_contract_count, flagged_total_value, risk_total_score, latest_publication_date|
          next if source_id.nil? || target_id.nil? || source_id == target_id

          {
            source_id: source_id,
            target_id: target_id,
            contract_count: contract_count.to_i,
            total_value: total_value.to_f,
            flagged_contract_count: flagged_contract_count.to_i,
            flagged_total_value: flagged_total_value.to_f,
            risk_total_score: risk_total_score.to_i,
            latest_publication_date: latest_publication_date
          }
        end

      edge_rows
    end

    def apply_preaggregated_date_filters(scope)
      scoped = scope
      scoped = scoped.where("publication_date >= ?", @date_from) if @date_from
      scoped = scoped.where("publication_date <= ?", @date_to) if @date_to
      scoped
    end

    def apply_preaggregated_data_source_filter(scope)
      return scope if @data_source_ids.blank?

      scope.where(data_source_id: @data_source_ids)
    end

    def apply_preaggregated_isolate_filter(scope)
      focus_ids = isolate_focus_entity_ids
      return scope if focus_ids.empty?

      edge_scope = scope.reselect("source_entity_id", "target_entity_id")
      reachable_ids = recursive_isolate_entity_ids(edge_scope, focus_ids)
      return scope.none if reachable_ids.empty?

      scope.where(source_entity_id: reachable_ids, target_entity_id: reachable_ids)
    end

    def recursive_isolate_entity_ids(scope, focus_ids)
      seeds = Array(focus_ids).filter_map { |id| Integer(id, exception: false) }.uniq
      return [] if seeds.empty?

      edges_sql = scope.to_sql

      seed_sql = seeds.map { |id| "SELECT #{id} AS entity_id, 0 AS depth" }.join(" UNION ALL ")

      sql = <<~SQL
        WITH RECURSIVE
          filtered_edges AS (
            SELECT source_entity_id, target_entity_id
            FROM (#{edges_sql}) AS candidate_edges
            WHERE source_entity_id IS NOT NULL AND target_entity_id IS NOT NULL
          ),
          seed_nodes(entity_id, depth) AS (
            #{seed_sql}
          ),
          neighborhood(entity_id, depth) AS (
            SELECT entity_id, depth FROM seed_nodes
            UNION
            SELECT
              CASE
                WHEN filtered_edges.source_entity_id = neighborhood.entity_id THEN filtered_edges.target_entity_id
                ELSE filtered_edges.source_entity_id
              END AS entity_id,
              neighborhood.depth + 1
            FROM filtered_edges
            JOIN neighborhood
              ON filtered_edges.source_entity_id = neighborhood.entity_id
              OR filtered_edges.target_entity_id = neighborhood.entity_id
            WHERE neighborhood.depth < #{ISOLATE_RECURSIVE_DEPTH}
          )
        SELECT DISTINCT entity_id
        FROM neighborhood
      SQL

      ActiveRecord::Base.connection.select_values(sql).filter_map { |value| Integer(value, exception: false) }.uniq
    end

    def apply_preaggregated_node_type_filters(scope)
      return scope if @include_public_bodies && @include_companies

      source_predicate = preaggregated_node_type_predicate("source")
      target_predicate = preaggregated_node_type_predicate("target")

      scope.where("(#{source_predicate}) AND (#{target_predicate})")
    end

    def preaggregated_node_type_predicate(prefix)
      predicates = []
      predicates << "#{prefix}_is_public_body = 1" if @include_public_bodies
      predicates << "#{prefix}_is_company = 1" if @include_companies
      predicates.join(" OR ")
    end

    def apply_isolate_filter(scope)
      focus_ids = isolate_focus_entity_ids
      return scope if focus_ids.empty?

      edge_scope = scope.reselect(
        "contracts.contracting_entity_id AS source_entity_id",
        "contract_winners.entity_id AS target_entity_id"
      )
      reachable_ids = recursive_isolate_entity_ids(edge_scope, focus_ids)
      return scope.none if reachable_ids.empty?

      scope.where(
        "contracts.contracting_entity_id IN (:reachable_ids) AND contract_winners.entity_id IN (:reachable_ids)",
        reachable_ids: reachable_ids
      )
    end

    def isolate_focus_entity_ids
      return [] unless @isolate_network

      @must_include_entity_ids
    end

    def apply_node_type_filters(scope)
      return scope if @include_public_bodies && @include_companies

      scoped = scope
        .joins("INNER JOIN entities contracting_entities ON contracting_entities.id = contracts.contracting_entity_id")
        .joins("INNER JOIN entities winner_entities ON winner_entities.id = contract_winners.entity_id")

      contracting_predicate = node_type_predicate("contracting_entities")
      winner_predicate = node_type_predicate("winner_entities")

      scoped.where("(#{contracting_predicate}) AND (#{winner_predicate})")
    end

    def node_type_predicate(table_alias)
      predicates = []
      predicates << "#{table_alias}.is_public_body = 1" if @include_public_bodies
      predicates << "#{table_alias}.is_company = 1" if @include_companies
      predicates.join(" OR ")
    end

    def apply_date_filters(scope)
      scoped = scope
      scoped = scoped.where("contracts.publication_date >= ?", @date_from) if @date_from
      scoped = scoped.where("contracts.publication_date <= ?", @date_to) if @date_to
      scoped
    end

    def apply_data_source_filter(scope)
      return scope if @data_source_ids.blank?

      scope.where(contracts: { data_source_id: @data_source_ids })
    end

    def parse_data_source_ids(value)
      return nil if value.blank?

      Array(value).filter_map { |id| Integer(id, exception: false) }.presence
    end

    def parse_must_include_entity_ids(value)
      return [] if value.blank?

      Array(value).filter_map { |id| Integer(id, exception: false) }
    end

    def expand_with_forced_entities(node_ids)
      return node_ids if @must_include_entity_ids.blank?

      existing = node_ids.to_set
      to_add = @must_include_entity_ids.reject { |id| existing.include?(id) }
      node_ids + to_add
    end

    def build_node_scores(edge_rows)
      node_scores = {}

      edge_rows.each do |row|
        source_stats = node_scores[row[:source_id]] ||= blank_node_metrics
        source_stats[:contract_count] += row[:contract_count]
        source_stats[:total_value] += row[:total_value]
        source_stats[:flagged_contract_count] += row[:flagged_contract_count]
        source_stats[:flagged_total_value] += row[:flagged_total_value]
        source_stats[:risk_total_score] += row[:risk_total_score]
        source_stats[:outgoing_contract_count] += row[:contract_count]
        source_stats[:latest_publication_date] = [ source_stats[:latest_publication_date], row[:latest_publication_date] ].compact.max

        target_stats = node_scores[row[:target_id]] ||= blank_node_metrics
        target_stats[:contract_count] += row[:contract_count]
        target_stats[:total_value] += row[:total_value]
        target_stats[:flagged_contract_count] += row[:flagged_contract_count]
        target_stats[:flagged_total_value] += row[:flagged_total_value]
        target_stats[:risk_total_score] += row[:risk_total_score]
        target_stats[:incoming_contract_count] += row[:contract_count]
        target_stats[:latest_publication_date] = [ target_stats[:latest_publication_date], row[:latest_publication_date] ].compact.max
      end

      node_scores
    end

    def blank_node_metrics
      {
        contract_count: 0,
        total_value: 0.0,
        flagged_contract_count: 0,
        flagged_total_value: 0.0,
        risk_total_score: 0,
        outgoing_contract_count: 0,
        incoming_contract_count: 0,
        latest_publication_date: nil
      }
    end

    def build_nodes(node_ids, entities, node_scores)
      node_ids.filter_map do |entity_id|
        entity = entities[entity_id]
        next unless entity

        stats = node_scores[entity_id] || blank_node_metrics

        {
          id: entity_node_id(entity.id),
          entity_id: entity.id,
          label: entity.name,
          node_type: entity_node_type(entity),
          is_focus: false,
          metrics: {
            contract_count: stats[:contract_count],
            total_value: stats[:total_value].round(2),
            flagged_contract_count: stats[:flagged_contract_count],
            flagged_total_value: stats[:flagged_total_value].round(2),
            risk_total_score: stats[:risk_total_score],
            outgoing_contract_count: stats[:outgoing_contract_count],
            incoming_contract_count: stats[:incoming_contract_count],
            latest_publication_date: format_date(stats[:latest_publication_date])
          }
        }
      end
    end

    def build_edges(edge_rows)
      edge_rows.map do |row|
        {
          id: "edge-#{row[:source_id]}-#{row[:target_id]}",
          source: entity_node_id(row[:source_id]),
          target: entity_node_id(row[:target_id]),
          edge_type: "award_link",
          metrics: {
            contract_count: row[:contract_count],
            total_value: row[:total_value].round(2),
            flagged_contract_count: row[:flagged_contract_count],
            flagged_total_value: row[:flagged_total_value].round(2),
            risk_total_score: row[:risk_total_score],
            latest_publication_date: format_date(row[:latest_publication_date])
          }
        }
      end
    end

    def summary_metrics(edge_rows, connected_individual_count)
      {
        total_contract_count: edge_rows.sum { |row| row[:contract_count] },
        total_value: edge_rows.sum { |row| row[:total_value] }.round(2),
        total_flagged_contract_count: edge_rows.sum { |row| row[:flagged_contract_count] },
        total_flagged_value: edge_rows.sum { |row| row[:flagged_total_value] }.round(2),
        total_risk_score: edge_rows.sum { |row| row[:risk_total_score] },
        connected_individual_count: connected_individual_count
      }
    end

    def build_individual_layers(entity_ids, entity_name_map)
      records = measure_timing(:individual_records_fetch) { individual_records(entity_ids) }
      connected_individual_count = records.map { |record| record[:pseudonym_seed] }.uniq.length
      return [ [], [], [], connected_individual_count ] if records.empty?

      grouped_nodes = records.group_by { |record| individual_node_id(record[:pseudonym_seed]) }
      shared_edges = measure_timing(:shared_individual_edges_build) { build_shared_individual_edges(grouped_nodes) }
      return [ [], [], shared_edges, connected_individual_count ] unless @include_individuals

      nodes = measure_timing(:individual_nodes_build) do
        grouped_nodes.map do |individual_id, grouped_records|
          build_individual_node(individual_id, grouped_records, entity_name_map)
        end
      end
      edges = measure_timing(:individual_edges_build) { build_individual_edges(records) }
      measure_timing(:individual_contract_enrichment) do
        enrich_individual_nodes_with_contract_metrics!(nodes, grouped_nodes, entity_ids)
      end

      [ nodes, edges, shared_edges, connected_individual_count ]
    end

    def individual_records(entity_ids)
      ids = Array(entity_ids).compact.uniq
      return [] if ids.empty?

      role_rows = limited_entity_person_role_rows(ids)
      role_records = role_rows.filter_map do |row|
        entity_id = Integer(row["entity_id"], exception: false)
        next unless entity_id

        person_id = Integer(row["person_id"], exception: false)
        person_tax_identifier = row["person_tax_identifier"].to_s

        {
          entity_id: entity_id,
          role_type: row["role_type"],
          role_label: person_role_label(row),
          name: row["person_name"].to_s,
          source_name: row["source_name"],
          active: ActiveModel::Type::Boolean.new.cast(row["active"]),
          start_date: parse_sql_date(row["start_date"]),
          end_date: parse_sql_date(row["end_date"]),
          pseudonym_seed: person_tax_identifier.present? ? "nif-#{person_tax_identifier}" : "person-#{person_id || "unknown"}"
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

    def limited_entity_person_role_rows(entity_ids)
      ranked_scope = EntityPersonRole.active
        .left_joins(:person)
        .where(entity_id: entity_ids)
        .select(
          "entity_person_roles.entity_id AS entity_id",
          "entity_person_roles.role_type AS role_type",
          "entity_person_roles.role_label AS role_label",
          "entity_person_roles.source_name AS source_name",
          "entity_person_roles.active AS active",
          "entity_person_roles.start_date AS start_date",
          "entity_person_roles.end_date AS end_date",
          "entity_person_roles.person_id AS person_id",
          "people.name AS person_name",
          "people.tax_identifier AS person_tax_identifier",
          "ROW_NUMBER() OVER (PARTITION BY entity_person_roles.entity_id ORDER BY COALESCE(entity_person_roles.verified_at, entity_person_roles.created_at) DESC, entity_person_roles.id DESC) AS row_rank"
        )

      ActiveRecord::Base.connection.select_all(<<~SQL)
        SELECT
          entity_id,
          role_type,
          role_label,
          source_name,
          active,
          start_date,
          end_date,
          person_id,
          person_name,
          person_tax_identifier
        FROM (#{ranked_scope.to_sql}) AS ranked_roles
        WHERE row_rank <= #{INDIVIDUAL_ROLE_LIMIT_PER_ENTITY}
      SQL
    end

    def person_role_label(row)
      row["role_label"].presence || row["role_type"].to_s.humanize
    end

    def parse_sql_date(value)
      return value if value.is_a?(Date)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
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
          flagged_contract_count: 0,
          flagged_total_value: 0.0,
          risk_total_score: 0,
          role_type: grouped_records.map { |record| record[:role_type] }.uniq.join(", "),
          role_label: grouped_records.map { |record| record[:role_label] }.uniq.join(", "),
          source_name: grouped_records.map { |record| record[:source_name] }.uniq.join(", "),
          connected_entity_ids: connected_entity_ids,
          connected_entity_labels: connected_entity_ids.map { |entity_id| entity_name_map[entity_id] }.compact,
          connected_entity_count: connected_entity_ids.size,
          involved_contract_count: 0,
          involved_total_value: 0.0,
          risk_flagged_contract_count: 0,
          risk_flagged_total_value: 0.0,
          active: grouped_records.any? { |record| record[:active] },
          start_date: format_date(grouped_records.map { |record| record[:start_date] }.compact.min),
          end_date: format_date(grouped_records.map { |record| record[:end_date] }.compact.max)
        }
      }
    end

    def build_individual_edges(records)
      grouped_edges = records.group_by { |record| [ record[:entity_id], individual_node_id(record[:pseudonym_seed]) ] }

      grouped_edges.map do |(entity_id, individual_id), grouped_records|
        {
          id: "edge-role-#{entity_id}-#{individual_id}",
          source: entity_node_id(entity_id),
          target: individual_id,
          edge_type: "entity_role_link",
          metrics: {
            contract_count: 0,
            total_value: 0.0,
            flagged_contract_count: 0,
            flagged_total_value: 0.0,
            risk_total_score: 0,
            role_type: grouped_records.map { |record| record[:role_type] }.uniq.join(", "),
            role_label: grouped_records.map { |record| record[:role_label] }.uniq.join(", "),
            source_name: grouped_records.map { |record| record[:source_name] }.uniq.join(", "),
            active: grouped_records.any? { |record| record[:active] },
            start_date: format_date(grouped_records.map { |record| record[:start_date] }.compact.min),
            end_date: format_date(grouped_records.map { |record| record[:end_date] }.compact.max),
            latest_publication_date: nil
          }
        }
      end
    end

    def build_shared_individual_edges(grouped_nodes)
      shared_pairs = {}

      grouped_nodes.each_value do |records|
        entity_ids = records.map { |record| record[:entity_id] }.compact.uniq.sort
        next if entity_ids.length < 2

        entity_ids.combination(2) do |source_id, target_id|
          pair = shared_pairs[[ source_id, target_id ]] ||= {
            source_id: source_id,
            target_id: target_id,
            shared_individual_count: 0,
            role_labels: Set.new,
            source_names: Set.new
          }
          pair[:shared_individual_count] += 1
          records.each do |record|
            pair[:role_labels] << record[:role_label].to_s if record[:role_label].present?
            pair[:source_names] << record[:source_name].to_s if record[:source_name].present?
          end
        end
      end

      shared_pairs.values.map do |pair|
        {
          id: "edge-shared-individual-#{pair[:source_id]}-#{pair[:target_id]}",
          source: entity_node_id(pair[:source_id]),
          target: entity_node_id(pair[:target_id]),
          edge_type: "shared_individual_link",
          metrics: {
            contract_count: 0,
            total_value: 0.0,
            flagged_contract_count: 0,
            flagged_total_value: 0.0,
            risk_total_score: 0,
            shared_individual_count: pair[:shared_individual_count],
            role_label: pair[:role_labels].to_a.sort.join(", "),
            source_name: pair[:source_names].to_a.sort.join(", "),
            latest_publication_date: nil
          }
        }
      end
    end

    def enrich_individual_nodes_with_contract_metrics!(nodes, grouped_nodes, entity_ids)
      return if nodes.empty?
      if entity_ids.size > INDIVIDUAL_CONTRACT_ENRICHMENT_ENTITY_LIMIT
        @instrumentation[:individual_contract_enrichment_skipped] = true if @instrumentation
        return
      end

      entity_to_contract_ids, contract_values, risk_by_contract = entity_contract_mappings(entity_ids)
      return if contract_values.empty?

      metrics_cache = {}

      nodes.each do |node|
        individual_records = grouped_nodes[node[:id]] || []
        connected_entity_ids = if individual_records.any?
          individual_records.map { |record| record[:entity_id] }.uniq
        else
          Array(node.dig(:metrics, :connected_entity_ids))
        end

        cache_key = connected_entity_ids.sort.join(",")
        metrics = metrics_cache[cache_key] ||= compute_individual_contract_metrics(
          connected_entity_ids: connected_entity_ids,
          entity_to_contract_ids: entity_to_contract_ids,
          contract_values: contract_values,
          risk_by_contract: risk_by_contract
        )

        node[:metrics][:connected_entity_count] = connected_entity_ids.size
        node[:metrics][:involved_contract_count] = metrics[:involved_contract_count]
        node[:metrics][:involved_total_value] = metrics[:involved_total_value]
        node[:metrics][:risk_total_score] = metrics[:risk_total_score]
        node[:metrics][:risk_flagged_contract_count] = metrics[:risk_flagged_contract_count]
        node[:metrics][:risk_flagged_total_value] = metrics[:risk_flagged_total_value]
      end
    end

    def compute_individual_contract_metrics(connected_entity_ids:, entity_to_contract_ids:, contract_values:, risk_by_contract:)
      involved_contract_ids = connected_entity_ids.each_with_object(Set.new) do |entity_id, memo|
        memo.merge(entity_to_contract_ids[entity_id])
      end

      involved_total_value = 0.0
      risk_total_score = 0
      flagged_count = 0
      flagged_total_value = 0.0

      involved_contract_ids.each do |contract_id|
        contract_value = contract_values.fetch(contract_id, 0.0)
        involved_total_value += contract_value
        contract_risk_score = risk_by_contract.fetch(contract_id, 0)
        next if contract_risk_score.zero?

        risk_total_score += contract_risk_score
        flagged_count += 1
        flagged_total_value += contract_value
      end

      {
        involved_contract_count: involved_contract_ids.size,
        involved_total_value: involved_total_value.round(2),
        risk_total_score: risk_total_score,
        risk_flagged_contract_count: flagged_count,
        risk_flagged_total_value: flagged_total_value.round(2)
      }
    end

    def entity_contract_mappings(entity_ids)
      ids = Array(entity_ids).compact.uniq
      return [ Hash.new { |h, k| h[k] = Set.new }, {}, {} ] if ids.empty?

      contracting_scope = apply_date_filters(Contract.where(contracting_entity_id: ids))
      winner_scope = apply_date_filters(ContractWinner.joins(:contract).where(entity_id: ids))
      focus_ids = isolate_focus_entity_ids
      if focus_ids.present?
        contracting_scope = contracting_scope
          .left_joins(:contract_winners)
          .where(
            "contracts.contracting_entity_id IN (:focus_ids) OR contract_winners.entity_id IN (:focus_ids)",
            focus_ids: focus_ids
          )
          .distinct

        winner_scope = winner_scope.where(
          "contracts.contracting_entity_id IN (:focus_ids) OR contract_winners.entity_id IN (:focus_ids)",
          focus_ids: focus_ids
        )
      end

      contract_rows = contracting_scope.pluck(
        Arel.sql("contracts.id"),
        Arel.sql("contracts.contracting_entity_id"),
        Arel.sql("contracts.base_price")
      )

      winner_rows = winner_scope.pluck(
        Arel.sql("contract_winners.contract_id"),
        Arel.sql("contract_winners.entity_id"),
        Arel.sql("contracts.base_price")
      )

      entity_to_contract_ids = Hash.new { |h, k| h[k] = Set.new }
      contract_values = {}
      contract_rows.each do |contract_id, contracting_entity_id, base_price|
        entity_to_contract_ids[contracting_entity_id] << contract_id
        contract_values[contract_id] ||= base_price.to_f
      end

      winner_rows.each do |contract_id, entity_id, base_price|
        entity_to_contract_ids[entity_id] << contract_id
        contract_values[contract_id] ||= base_price.to_f
      end

      return [ entity_to_contract_ids, {}, {} ] if contract_rows.empty? && winner_rows.empty?

      contract_ids_scope = union_contract_ids_scope(contracting_scope, winner_scope)

      risk_by_contract = Flag.where(contract_id: contract_ids_scope).group(:contract_id).sum(:score)

      [ entity_to_contract_ids, contract_values, risk_by_contract ]
    end

    def union_contract_ids_scope(contracting_scope, winner_scope)
      contracting_ids_sql = contracting_scope.select("contracts.id AS id").to_sql
      winner_ids_sql = winner_scope.select("contract_winners.contract_id AS id").to_sql

      Contract.unscoped
        .from("(#{contracting_ids_sql} UNION #{winner_ids_sql}) AS scoped_contract_ids")
        .select("scoped_contract_ids.id")
    end

    def entity_node_id(entity_id)
      "entity-#{entity_id}"
    end

    def entity_node_type(entity)
      entity.is_public_body? ? "public_body" : "company"
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
      return DEFAULT_NODE_LIMIT unless parsed

      [ [ parsed, MIN_NODE_LIMIT ].max, MAX_NODE_LIMIT ].min
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

    def empty_payload
      {
        nodes: [],
        edges: [],
        meta: {
          includes_people: false,
          includes_tax_identifier: false,
          anonymization_mode: "none",
          node_limit: @node_limit,
          total_nodes: 0,
          total_edges: 0,
          truncated: false,
          filters: {
            date_from: @date_from&.iso8601,
            date_to: @date_to&.iso8601,
            include_public_bodies: @include_public_bodies,
            include_companies: @include_companies,
            isolate_network: @isolate_network
          },
          summary: {
            total_contract_count: 0,
            total_value: 0.0,
            total_flagged_contract_count: 0,
            total_flagged_value: 0.0,
            total_risk_score: 0,
            connected_individual_count: 0
          }
        }
      }
    end
  end
end
