# frozen_string_literal: true

require "csv"

module PublicContracts
  class EntityPeopleEnrichmentService
    SOURCE_NAME = "Registo Comercial"

    def initialize(scraper: PT::RegistoComercial.new, relation: Entity.where(country_code: "PT", is_company: true))
      @scraper = scraper
      @relation = relation
    end

    def call(nif: nil, input: nil, limit: nil, offset: nil)
      stats = { processed: 0, updated: 0, skipped: 0 }

      target_relation(nif:, input:, limit:, offset:).find_each do |entity|
        stats[:processed] += 1

        if enrich_entity(entity)
          stats[:updated] += 1
        else
          stats[:skipped] += 1
        end
      end

      stats
    end

    def enrich_entity(entity)
      detail, source_url, source_publication_date = latest_publication_with_people(@scraper.investigar(entity.tax_identifier))
      return false unless detail

      sync_people(entity, detail.fetch(:people), source_url:, source_publication_date:)
      true
    end

    private

    def target_relation(nif:, input:, limit:, offset:)
      relation = @relation

      nifs = []
      nifs << normalize_nif(nif) if nif.present?
      nifs.concat(read_input_nifs(input)) if input.present?
      nifs = nifs.compact.uniq

      relation = relation.where(tax_identifier: nifs) if nifs.any?

      relation = relation.offset(offset.to_i) if offset.present?
      relation = relation.limit(limit.to_i) if limit.present?
      relation
    end

    def read_input_nifs(input)
      path = Pathname.new(input)
      return [] unless path.exist?

      text = path.read
      return text.lines.map { |line| normalize_nif(line) }.compact if path.extname.downcase != ".csv"

      CSV.parse(text, headers: true).flat_map do |row|
        row.fields.map { |field| normalize_nif(field) }
      end.compact
    end

    def normalize_nif(value)
      digits = value.to_s.gsub(/\D/, "")
      digits if digits.length == 9
    end

    def latest_publication_with_people(publications)
      Array(publications).each do |publication|
        detail = publication[:detalhe]
        next unless detail.is_a?(Hash)

        people = Array(detail[:people]).presence || legacy_people(detail)
        next if people.empty?

        return [
          detail.merge(people: people),
          publication[:ligacao].is_a?(String) ? publication[:ligacao] : nil,
          parse_date(publication[:data]) || parse_date(detail[:data_publicacao])
        ]
      end

      nil
    end

    def legacy_people(detail)
      Array(detail[:gerentes]).map { |name| build_person_hash(name, "manager", "Gerente") } +
        Array(detail[:socios]).map { |name| build_person_hash(name, "partner_shareholder", "Sócio") }
    end

    def build_person_hash(name, role_type, role_label)
      {
        name: name,
        role_type: role_type,
        role_label: role_label,
        tax_identifier: nil
      }
    end

    def sync_people(entity, people, source_url:, source_publication_date:)
      desired_keys = []

      people.each do |attributes|
        next if attributes[:name].blank?

        person = find_or_initialize_person(entity, attributes)
        person.assign_attributes(
          name: attributes[:name],
          country_code: entity.country_code,
          tax_identifier: attributes[:tax_identifier].presence
        )
        person.save! if person.new_record? || person.changed?

        role = entity.entity_person_roles.find_or_initialize_by(
          person: person,
          role_type: attributes[:role_type],
          source_name: SOURCE_NAME,
          active: true
        )
        role.role_label = attributes[:role_label]
        role.source_url = source_url
        role.source_publication_date = source_publication_date
        role.verified_at = Time.current
        role.save! if role.new_record? || role.changed?

        desired_keys << [ person.id, attributes[:role_type] ]
      end

      entity.entity_person_roles.active.where(source_name: SOURCE_NAME).includes(:person).find_each do |role|
        next if desired_keys.include?([ role.person_id, role.role_type ])

        role.update!(active: false, verified_at: Time.current)
      end
    end

    def find_or_initialize_person(entity, attributes)
      tax_identifier = attributes[:tax_identifier].presence
      return Person.find_or_initialize_by(tax_identifier:, country_code: entity.country_code) if tax_identifier

      entity.people.find_by(name: attributes[:name], country_code: entity.country_code) || Person.new
    end

    def parse_date(value)
      return if value.blank?

      Date.parse(value.to_s)
    rescue Date::Error
      nil
    end
  end
end