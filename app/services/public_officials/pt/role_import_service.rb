# frozen_string_literal: true

require "digest"

module PublicOfficials
  module PT
    class RoleImportService
      SOURCE_NAME = "DRE"

      Stats = Struct.new(:processed, :updated, :skipped, keyword_init: true)

      def initialize(records:)
        @records = Array(records)
      end

      def call
        stats = Stats.new(processed: 0, updated: 0, skipped: 0)

        @records.each do |record|
          stats.processed += 1
          if import_record(record)
            stats.updated += 1
          else
            stats.skipped += 1
          end
        end

        stats
      end

      private

      def import_record(record)
        attributes = normalize_record(record)
        return false if attributes[:person_name].blank? || attributes[:public_entity_name].blank?

        entity = find_or_create_public_entity(attributes)
        person = find_or_create_person(entity, attributes)
        sync_role(entity, person, attributes)
        true
      end

      def normalize_record(record)
        data = record.respond_to?(:to_h) ? record.to_h : {}
        {
          person_name: data[:person_name].presence || data["person_name"].presence,
          person_tax_identifier: normalize_nif(data[:person_tax_identifier] || data["person_tax_identifier"]),
          public_entity_tax_identifier: normalize_entity_identifier(data[:public_entity_tax_identifier] || data["public_entity_tax_identifier"], data[:public_entity_name] || data["public_entity_name"]),
          public_entity_name: data[:public_entity_name].presence || data["public_entity_name"].presence,
          role_type: normalize_role_type(data[:role_type] || data["role_type"]),
          role_label: (data[:role_label].presence || data["role_label"].presence || "Public official"),
          start_date: parse_date(data[:start_date] || data["start_date"]),
          end_date: parse_date(data[:end_date] || data["end_date"]),
          source_name: data[:source_name].presence || data["source_name"].presence || SOURCE_NAME,
          source_url: data[:source_url].presence || data["source_url"].presence,
          source_publication_date: parse_date(data[:source_publication_date] || data["source_publication_date"])
        }
      end

      def find_or_create_public_entity(attributes)
        Entity.find_or_initialize_by(
          tax_identifier: attributes[:public_entity_tax_identifier],
          country_code: "PT"
        ).tap do |entity|
          entity.name = attributes[:public_entity_name]
          entity.is_public_body = true
          entity.is_company = false if entity.is_company.nil?
          entity.save! if entity.new_record? || entity.changed?
        end
      end

      def find_or_create_person(entity, attributes)
        tax_identifier = attributes[:person_tax_identifier].presence
        person = if tax_identifier
          Person.find_or_initialize_by(tax_identifier:, country_code: "PT")
        else
          entity.people.find_by(name: attributes[:person_name], country_code: "PT") || Person.new
        end

        person.name = attributes[:person_name]
        person.country_code = "PT"
        person.tax_identifier = tax_identifier
        person.save! if person.new_record? || person.changed?
        person
      end

      def sync_role(entity, person, attributes)
        role = entity.entity_person_roles.find_or_initialize_by(
          person: person,
          role_type: attributes[:role_type],
          source_name: attributes[:source_name],
          start_date: attributes[:start_date]
        )
        role.role_label = attributes[:role_label]
        role.source_url = attributes[:source_url]
        role.source_publication_date = attributes[:source_publication_date]
        role.end_date = attributes[:end_date]
        role.active = attributes[:end_date].nil?
        role.verified_at = Time.current
        role.save! if role.new_record? || role.changed?
      end

      def normalize_nif(value)
        digits = value.to_s.gsub(/\D/, "")
        digits if digits.length == 9
      end

      def normalize_entity_identifier(value, name)
        normalize_nif(value) || synthetic_entity_identifier(name)
      end

      def synthetic_entity_identifier(name)
        "PT-PUBLIC-#{Digest::MD5.hexdigest(name.to_s.downcase.strip)[0, 12]}"
      end

      def normalize_role_type(value)
        role_type = value.to_s.presence || "unknown"
        return role_type if EntityPersonRole::ROLE_TYPES.include?(role_type)

        "unknown"
      end

      def parse_date(value)
        return if value.blank?

        Date.parse(value.to_s)
      rescue Date::Error
        nil
      end
    end
  end
end
