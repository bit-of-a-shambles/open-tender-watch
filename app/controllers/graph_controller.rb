# frozen_string_literal: true

require "openssl"

class GraphController < ApplicationController
  NETWORK_MAP_CACHE_VERSION = "v9"
  NETWORK_MAP_CACHE_TTL = 60.minutes

  def search_entities
    q = params[:q].to_s.strip
    results = []

    if q.length >= 2
      results.concat(entity_search_results(q))
      results.concat(individual_search_results(q)) if journalist_access?
    end

    render json: { results: results.first(20) }
  end

  def entity_network
    entity = Entity.find(params[:entity_id])

    payload = Rails.cache.fetch(graph_cache_key(entity), expires_in: 10.minutes) do
      Graph::EntityNetworkService.new(
        entity: entity,
        date_from: params[:date_from],
        date_to: params[:date_to],
        neighbor_limit: params[:limit],
        include_individuals: include_individuals_requested?
      ).call
    end

    render json: payload
  end

  def network_map
    cache_key = network_map_cache_key
    request_started_at = monotonic_now
    cache_hit = true
    service_instrumentation = {}

    payload = Rails.cache.fetch(cache_key, expires_in: NETWORK_MAP_CACHE_TTL) do
      cache_hit = false
      Graph::NetworkMapService.new(
        date_from: params[:date_from],
        date_to: params[:date_to],
        node_limit: params[:limit],
        include_individuals: include_individuals_requested?,
        include_public_bodies: include_public_bodies_requested?,
        include_companies: include_companies_requested?,
        data_source_ids: params[:data_source_ids],
        must_include_entity_ids: params[:must_include_entity_ids],
        isolate_network: isolate_network_requested?,
        instrumentation: service_instrumentation
      ).call
    end

    log_network_map_telemetry(
      cache_key: cache_key,
      cache_hit: cache_hit,
      request_ms: elapsed_ms(request_started_at),
      service: service_instrumentation.presence
    )

    render json: payload
  end

  private

  def graph_cache_key(entity)
    [
      "graph",
      "entity-network",
      "v4",
      entity.id,
      params[:date_from].presence || "none",
      params[:date_to].presence || "none",
      params[:limit].presence || Graph::EntityNetworkService::DEFAULT_NEIGHBOR_LIMIT,
      include_individuals_requested? ? "with-individuals" : "entities-only",
      current_access_level
    ].join(":")
  end

  def include_individuals_requested?
    journalist_access? && ActiveModel::Type::Boolean.new.cast(params[:include_individuals])
  end

  def include_public_bodies_requested?
    cast_boolean_with_default(params[:include_public_bodies], default: true)
  end

  def include_companies_requested?
    cast_boolean_with_default(params[:include_companies], default: true)
  end

  def isolate_network_requested?
    cast_boolean_with_default(params[:isolate_network], default: must_include_entity_ids_present?)
  end

  def must_include_entity_ids_present?
    Array(params[:must_include_entity_ids]).any? { |id| Integer(id, exception: false) }
  end

  def cast_boolean_with_default(value, default:)
    return default if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def network_map_cache_key
    data_source_key = Array(params[:data_source_ids]).sort.join("-").presence || "all"
    forced_key = Array(params[:must_include_entity_ids]).sort.join("-").presence || "none"
    [
      "graph",
      "network-map",
      NETWORK_MAP_CACHE_VERSION,
      params[:date_from].presence || "none",
      params[:date_to].presence || "none",
      params[:limit].presence || Graph::NetworkMapService::DEFAULT_NODE_LIMIT,
      include_public_bodies_requested? ? "public-bodies" : "no-public-bodies",
      include_companies_requested? ? "companies" : "no-companies",
      include_individuals_requested? ? "with-individuals" : "entities-only",
      isolate_network_requested? ? "isolated-network" : "global-network",
      "sources-#{data_source_key}",
      "forced-#{forced_key}",
      current_access_level
    ].join(":")
  end

  def entity_search_results(query)
    normalized_query = query.to_s.strip.downcase
    return [] if normalized_query.blank?

    wildcard_query = "%#{ActiveRecord::Base.sanitize_sql_like(normalized_query)}%"
    digits_query = query.to_s.gsub(/\D/, "")

    scope = Entity.where("LOWER(name) LIKE ?", wildcard_query)
    if digits_query.present?
      wildcard_digits = "%#{ActiveRecord::Base.sanitize_sql_like(digits_query)}%"
      scope = scope.or(Entity.where("tax_identifier LIKE ?", wildcard_digits))
    end

    scope
      .order(:name)
      .limit(12)
      .pluck(:id, :name, :is_public_body, :is_company)
      .map do |id, name, is_public_body, is_company|
        node_type = is_public_body ? "public_body" : "company"
        { id: id, name: name, node_type: node_type, node_id: "entity-#{id}" }
      end
  end

  def individual_search_results(query)
    normalized_query = query.to_s.strip.downcase
    return [] if normalized_query.blank?

    wildcard_query = "%#{ActiveRecord::Base.sanitize_sql_like(normalized_query)}%"
    digits_query = query.to_s.gsub(/\D/, "")

    scope = Person
      .joins(:entity_person_roles)
      .merge(EntityPersonRole.active)
      .where.not(tax_identifier: [ nil, "" ])

    if digits_query.present?
      wildcard_digits = "%#{ActiveRecord::Base.sanitize_sql_like(digits_query)}%"
      scope = scope.where(
        "LOWER(people.name) LIKE :name_query OR people.tax_identifier LIKE :digits_query",
        name_query: wildcard_query,
        digits_query: wildcard_digits
      )
    else
      scope = scope.where("LOWER(people.name) LIKE ?", wildcard_query)
    end

    scope
      .group("people.tax_identifier", "people.name")
      .order(Arel.sql("COUNT(DISTINCT entity_person_roles.entity_id) DESC"), "people.name ASC")
      .limit(8)
      .pluck(
        Arel.sql("people.tax_identifier"),
        Arel.sql("people.name"),
        Arel.sql("COUNT(DISTINCT entity_person_roles.entity_id)"),
        Arel.sql("GROUP_CONCAT(DISTINCT entity_person_roles.entity_id)")
      )
      .map do |tax_identifier, name, entity_count, entity_ids_csv|
        node_id = individual_node_id("nif-#{tax_identifier}")
        {
          id: node_id,
          name: pseudonymised_individual_label(name, node_id),
          node_type: "individual",
          node_id: node_id,
          entity_count: entity_count.to_i,
          entity_ids: entity_ids_csv.to_s.split(",").filter_map { |id| Integer(id, exception: false) }
        }
      end
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

  def log_network_map_telemetry(cache_key:, cache_hit:, request_ms:, service:)
    payload = {
      cache_key: cache_key,
      cache_hit: cache_hit,
      request_ms: request_ms,
      service: service,
      access_level: current_access_level
    }

    ActiveSupport::Notifications.instrument("graph.network_map.request", payload)
    Rails.logger.info("graph.network_map.request #{payload}")
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started_at)
    ((monotonic_now - started_at) * 1000.0).round(1)
  end
end
