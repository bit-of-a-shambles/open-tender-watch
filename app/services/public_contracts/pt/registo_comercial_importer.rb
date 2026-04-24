# frozen_string_literal: true

require "json"

module PublicContracts
  module PT
    # Imports harvested Registo Comercial data for a single NIF into the database.
    # Builds a timeline of appointments (designações) and cessations for each
    # person, creating one EntityPersonRole per stint with start_date / end_date.
    #
    # Usage:
    #   importer = RegistoComercialImporter.new
    #   importer.import_nif("501412727", nif_data_hash)
    #
    # Can also import a full JSON file:
    #   importer.import_file("/tmp/rc_results.json")
    class RegistoComercialImporter
      SOURCE_NAME = "Registo Comercial"

      Stats = Struct.new(:processed, :updated, :skipped, :roles_created, keyword_init: true) do
        def merge!(other)
          self.processed += other.processed
          self.updated += other.updated
          self.skipped += other.skipped
          self.roles_created += other.roles_created
          self
        end
      end

      def import_nif(nif, nif_data)
        stats = Stats.new(processed: 1, updated: 0, skipped: 0, roles_created: 0)

        if nif_data["error"] || nif_data["totalResults"].to_i == 0
          stats.skipped = 1
          return stats
        end

        entity = Entity.find_by(tax_identifier: nif, country_code: "PT")
        unless entity
          stats.skipped = 1
          return stats
        end

        publications = Array(nif_data["publications"])
        events = build_events(publications)
        stints = build_stints(events)

        if stints.empty?
          stats.skipped = 1
          return stats
        end

        roles_count = sync_stints(entity, stints)
        stats.updated = 1
        stats.roles_created = roles_count
        stats
      end

      def import_file(path)
        data = JSON.parse(File.read(path))
        stats = Stats.new(processed: 0, updated: 0, skipped: 0, roles_created: 0)

        data.each do |nif, nif_data|
          nif_stats = import_nif(nif, nif_data)
          stats.merge!(nif_stats)
        end

        stats
      end

      private

      def build_events(publications)
        events = []

        publications.reverse_each do |pub|
          pub_date = parse_date(pub["date"])
          text = pub["text"].to_s

          parse_cessation_details(text).each do |c|
            events << c.merge(date: pub_date, type: :end)
          end

          parse_people_from_text(text).each do |person|
            key = normalize_key(person[:name], person[:role_type])
            events << person.merge(key: key, date: pub_date, type: :start)
          end
        end

        events
      end

      # ── People parsing ──────────────────────────────────────────

      def parse_people_from_text(text)
        people = []
        people.concat(parse_gerencia(text))
        people.concat(parse_socios(text))
        people.concat(parse_administracao(text))
        people
      end

      def parse_gerencia(text)
        people = []
        text.scan(/GER[ÊE]NCIA:\s*(.*?)(?=\n\s*(?:Data da deliberação|Os documentos|S[ÓO]CIOS|ADMINISTRA|GER[ÊE]NCIA:|\z))/mi) do |block_match|
          block = block_match[0]
          block.scan(/Nome\/Firma:\s*(.+?)(?:\n|$)/) do |name_match|
            name = name_match[0].strip
            after_name = block[block.index(name)..]
            nif = after_name[/NIF\/NIPC:\s*(\d{9})/i, 1]
            cessation = after_name =~ /Causa:\s*(?:ren[úu]ncia|destitui[çc][ãa]o|caducidade)/i
            next if cessation

            people << { name: name, role_type: "manager", role_label: "Gerente", tax_identifier: nif }
          end
        end
        people
      end

      def parse_socios(text)
        people = []
        text.scan(/S[ÓO]CIOS E QUOTAS:\s*(.*?)(?=\n\s*(?:Data da deliberação|Os documentos|GER[ÊE]NCIA|ADMINISTRA|\z))/mi) do |block_match|
          block = block_match[0]
          quota_blocks = block.split(/(?=QUOTA\s*:)/i)
          quota_blocks.each do |qb|
            qb.scan(/TITULAR:\s*(.+?)(?:\n|$)/) do |name_match|
              raw_name = name_match[0].strip
              nif = qb[/NIF\/NIPC:\s*(\d{9})/i, 1]
              people << { name: raw_name, role_type: "partner_shareholder", role_label: "Sócio", tax_identifier: nif }
            end
          end
        end
        people.uniq { |p| p[:name] }
      end

      def parse_administracao(text)
        people = []
        text.scan(/(?:CONSELHO DE )?ADMINISTRA[ÇC][ÃA]O:\s*(.*?)(?=\n\s*(?:Data da deliberação|Os documentos|S[ÓO]CIOS|GER[ÊE]NCIA|FISCAL|SUPLENTE|\z))/mi) do |block_match|
          block = block_match[0]
          block.scan(/Nome\/Firma:\s*(.+?)(?:\n|$)/) do |name_match|
            name = name_match[0].strip
            after_name = block[block.index(name)..]
            nif = after_name[/NIF\/NIPC:\s*(\d{9})/i, 1]
            cessation = after_name =~ /Causa:\s*(?:ren[úu]ncia|destitui[çc][ãa]o|caducidade)/i
            next if cessation

            cargo = after_name[/Cargo:\s*(.+?)(?:\n|$)/i, 1]&.strip || "Administrador"
            people << { name: name, role_type: "manager", role_label: cargo, tax_identifier: nif }
          end
        end

        text.scan(/FISCAL [ÚU]NICO:\s*(.*?)(?=\n\s*(?:Data da deliberação|Os documentos|S[ÓO]CIOS|GER[ÊE]NCIA|SUPLENTE|ADMINISTRA|\z))/mi) do |block_match|
          block = block_match[0]
          block.scan(/Nome\/Firma:\s*(.+?)(?:\n|$)/) do |name_match|
            name = name_match[0].strip
            after_name = block[block.index(name)..]
            nif = after_name[/NIF\/NIPC:\s*(\d{9})/i, 1]
            cessation = after_name =~ /Causa:\s*(?:ren[úu]ncia|destitui[çc][ãa]o|caducidade)/i
            next if cessation

            people << { name: name, role_type: "officer", role_label: "Fiscal Único", tax_identifier: nif }
          end
        end

        people
      end

      # ── Cessation parsing ───────────────────────────────────────

      def parse_cessation_details(text)
        ceased = []

        text.scan(/GER[ÊE]NCIA:\s*(.*?)(?=\n\s*(?:Data da deliberação|Os documentos|S[ÓO]CIOS|ADMINISTRA|GER[ÊE]NCIA:|\z))/mi) do |block_match|
          block = block_match[0]
          block.scan(/Nome\/Firma:\s*(.+?)(?:\n|$)/) do |name_match|
            name = name_match[0].strip
            after_name = block[block.index(name)..]
            if after_name =~ /Causa:\s*(?:ren[úu]ncia|destitui[çc][ãa]o|caducidade)/i
              key = normalize_key(name, "manager")
              nif = after_name[/NIF\/NIPC:\s*(\d{9})/i, 1]
              ceased << { key: key, name: name, role_type: "manager", role_label: "Gerente", tax_identifier: nif }
            end
          end
        end

        text.scan(/(?:CONSELHO DE )?ADMINISTRA[ÇC][ÃA]O:\s*(.*?)(?=\n\s*(?:Data da deliberação|Os documentos|S[ÓO]CIOS|GER[ÊE]NCIA|FISCAL|SUPLENTE|\z))/mi) do |block_match|
          block = block_match[0]
          block.scan(/Nome\/Firma:\s*(.+?)(?:\n|$)/) do |name_match|
            name = name_match[0].strip
            after_name = block[block.index(name)..]
            if after_name =~ /Causa:\s*(?:ren[úu]ncia|destitui[çc][ãa]o|caducidade)/i
              cargo = after_name[/Cargo:\s*(.+?)(?:\n|$)/i, 1]&.strip || "Administrador"
              key = normalize_key(name, "manager")
              nif = after_name[/NIF\/NIPC:\s*(\d{9})/i, 1]
              ceased << { key: key, name: name, role_type: "manager", role_label: cargo, tax_identifier: nif }
            end
          end
        end

        text.scan(/FISCAL [ÚU]NICO:\s*(.*?)(?=\n\s*(?:Data da deliberação|Os documentos|S[ÓO]CIOS|GER[ÊE]NCIA|SUPLENTE|ADMINISTRA|\z))/mi) do |block_match|
          block = block_match[0]
          block.scan(/Nome\/Firma:\s*(.+?)(?:\n|$)/) do |name_match|
            name = name_match[0].strip
            after_name = block[block.index(name)..]
            if after_name =~ /Causa:\s*(?:ren[úu]ncia|destitui[çc][ãa]o|caducidade)/i
              key = normalize_key(name, "officer")
              nif = after_name[/NIF\/NIPC:\s*(\d{9})/i, 1]
              ceased << { key: key, name: name, role_type: "officer", role_label: "Fiscal Único", tax_identifier: nif }
            end
          end
        end

        ceased
      end

      # ── Stint building ──────────────────────────────────────────

      def normalize_key(name, role_type)
        normalized = name.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.strip
        "#{normalized}|#{role_type}"
      end

      def build_stints(events)
        by_key = Hash.new { |h, k| h[k] = [] }
        events.each { |e| by_key[e[:key]] << e }

        stints = []

        by_key.each_value do |key_events|
          best_attrs = key_events.min_by { |e| e[:tax_identifier] ? 0 : 1 }
          open_stint = nil

          key_events.each do |event|
            if event[:type] == :start
              stints << open_stint if open_stint
              open_stint = {
                name: best_attrs[:name],
                role_type: best_attrs[:role_type],
                role_label: event[:role_label] || best_attrs[:role_label],
                tax_identifier: best_attrs[:tax_identifier] || event[:tax_identifier],
                start_date: event[:date],
                end_date: nil
              }
            elsif event[:type] == :end
              if open_stint
                open_stint[:end_date] = event[:date]
                stints << open_stint
                open_stint = nil
              else
                stints << {
                  name: best_attrs[:name],
                  role_type: best_attrs[:role_type],
                  role_label: event[:role_label] || best_attrs[:role_label],
                  tax_identifier: best_attrs[:tax_identifier] || event[:tax_identifier],
                  start_date: nil,
                  end_date: event[:date]
                }
              end
            end
          end

          stints << open_stint if open_stint
        end

        stints
      end

      # ── DB sync ─────────────────────────────────────────────────

      def sync_stints(entity, stints)
        created = 0

        stints.each do |stint|
          next if stint[:name].blank?

          person = find_or_initialize_person(entity, stint)
          person.assign_attributes(
            name: stint[:name],
            country_code: entity.country_code,
            tax_identifier: stint[:tax_identifier].presence
          )
          person.save! if person.new_record? || person.changed?

          active = stint[:end_date].nil?
          role = entity.entity_person_roles.find_or_initialize_by(
            person: person,
            role_type: stint[:role_type],
            source_name: SOURCE_NAME,
            start_date: stint[:start_date]
          )
          role.role_label = stint[:role_label]
          role.active = active
          role.start_date = stint[:start_date]
          role.end_date = stint[:end_date]
          role.source_publication_date = stint[:end_date] || stint[:start_date]
          role.verified_at = Time.current
          role.save! if role.new_record? || role.changed?
          created += 1
        end

        # Mark old roles from this source not in the stints as inactive
        stint_keys = stints.filter_map { |s|
          person = find_person(entity, s)
          next unless person
          [person.id, s[:role_type], s[:start_date]]
        }

        entity.entity_person_roles.where(active: true, source_name: SOURCE_NAME).includes(:person).find_each do |role|
          next if stint_keys.include?([role.person_id, role.role_type, role.start_date])
          role.update!(active: false, verified_at: Time.current)
        end

        created
      end

      def find_or_initialize_person(entity, attributes)
        tax_identifier = attributes[:tax_identifier].presence
        return Person.find_or_initialize_by(tax_identifier: tax_identifier, country_code: entity.country_code) if tax_identifier

        entity.people.find_by(name: attributes[:name], country_code: entity.country_code) || Person.new
      end

      def find_person(entity, attributes)
        tax_identifier = attributes[:tax_identifier].presence
        return Person.find_by(tax_identifier: tax_identifier, country_code: entity.country_code) if tax_identifier
        entity.people.find_by(name: attributes[:name], country_code: entity.country_code)
      end

      def parse_date(value)
        return nil if value.blank?
        Date.parse(value.to_s)
      rescue Date::Error
        nil
      end
    end
  end
end
