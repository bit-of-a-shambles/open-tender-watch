# frozen_string_literal: true

# Rails runner script to import pre-scraped Registo Comercial data.
# Usage: bundle exec rails runner script/import_scraped_rc.rb /tmp/rc_results.json
#
# Builds a timeline of appointments (designações) and cessations for each
# person, creating one EntityPersonRole per stint with start_date / end_date.

require "json"

json_path = ARGV[0] || "/tmp/rc_results.json"
abort "File not found: #{json_path}" unless File.exist?(json_path)

data = JSON.parse(File.read(json_path))
puts "Loaded #{data.size} NIFs from #{json_path}"

SOURCE_NAME = "Registo Comercial"

stats = { processed: 0, updated: 0, skipped: 0, roles_created: 0 }

data.each do |nif, nif_data|
  stats[:processed] += 1
  entity = Entity.find_by(tax_identifier: nif, country_code: "PT")

  unless entity
    puts "  ⚠ Entity not found for NIF #{nif} — skipping"
    stats[:skipped] += 1
    next
  end

  publications = Array(nif_data["publications"])

  # Build timeline events from publications (oldest-first for chronological processing)
  events = [] # { key:, name:, role_type:, role_label:, tax_identifier:, date:, type: :start/:end }

  publications.reverse_each do |pub|
    pub_date = parse_date(pub["date"])
    text = pub["text"].to_s

    # Cessations
    parse_cessation_details(text).each do |c|
      events << c.merge(date: pub_date, type: :end)
    end

    # Designations (appointments)
    parse_people_from_text(text).each do |person|
      key = normalize_key(person[:name], person[:role_type])
      events << person.merge(key: key, date: pub_date, type: :start)
    end
  end

  # Build stints: pair each :start with the next :end for the same key
  stints = build_stints(events)

  if stints.empty?
    puts "  #{nif} (#{entity.name}): no people found in #{publications.size} publications"
    stats[:skipped] += 1
    next
  end

  roles_count = sync_stints(entity, stints)

  puts "  ✓ #{nif} (#{entity.name}): #{stints.size} role stints synced (#{roles_count} DB records)"
  stats[:updated] += 1
  stats[:roles_created] += roles_count
end

puts
puts "Done: #{stats}"

BEGIN {
  def parse_people_from_text(text)
    people = []
    people.concat(parse_gerencia(text))
    people.concat(parse_socios(text))
    people.concat(parse_administracao(text))
    people
  end

  # Extract cessation details — returns array of hashes with name, role_type, key
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

  # Normalize name for comparison: strip accents + downcase
  def normalize_key(name, role_type)
    normalized = name.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.strip
    "#{normalized}|#{role_type}"
  end

  # Parse GERÊNCIA sections: Nome/Firma: X, NIF/NIPC: Y, Cargo: Gerente
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

        people << {
          name: name,
          role_type: "manager",
          role_label: "Gerente",
          tax_identifier: nif
        }
      end
    end
    people
  end

  # Parse SÓCIOS E QUOTAS sections
  def parse_socios(text)
    people = []
    text.scan(/S[ÓO]CIOS E QUOTAS:\s*(.*?)(?=\n\s*(?:Data da deliberação|Os documentos|GER[ÊE]NCIA|ADMINISTRA|\z))/mi) do |block_match|
      block = block_match[0]
      quota_blocks = block.split(/(?=QUOTA\s*:)/i)
      quota_blocks.each do |qb|
        qb.scan(/TITULAR:\s*(.+?)(?:\n|$)/) do |name_match|
          raw_name = name_match[0].strip
          nif = qb[/NIF\/NIPC:\s*(\d{9})/i, 1]

          people << {
            name: raw_name,
            role_type: "partner_shareholder",
            role_label: "Sócio",
            tax_identifier: nif
          }
        end
      end
    end
    people.uniq { |p| p[:name] }
  end

  # Parse ADMINISTRAÇÃO / CONSELHO DE ADMINISTRAÇÃO sections
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

        people << {
          name: name,
          role_type: "manager",
          role_label: cargo,
          tax_identifier: nif
        }
      end
    end

    # Parse FISCAL ÚNICO sections
    text.scan(/FISCAL [ÚU]NICO:\s*(.*?)(?=\n\s*(?:Data da deliberação|Os documentos|S[ÓO]CIOS|GER[ÊE]NCIA|SUPLENTE|ADMINISTRA|\z))/mi) do |block_match|
      block = block_match[0]
      block.scan(/Nome\/Firma:\s*(.+?)(?:\n|$)/) do |name_match|
        name = name_match[0].strip
        after_name = block[block.index(name)..]
        nif = after_name[/NIF\/NIPC:\s*(\d{9})/i, 1]
        cessation = after_name =~ /Causa:\s*(?:ren[úu]ncia|destitui[çc][ãa]o|caducidade)/i
        next if cessation

        people << {
          name: name,
          role_type: "officer",
          role_label: "Fiscal Único",
          tax_identifier: nif
        }
      end
    end

    people
  end

  # Build role stints from chronological events.
  # Each stint = { name:, role_type:, role_label:, tax_identifier:, start_date:, end_date: (nil if still active) }
  def build_stints(events)
    # Group events by normalized key
    by_key = Hash.new { |h, k| h[k] = [] }
    events.each { |e| by_key[e[:key]] << e }

    stints = []

    by_key.each do |_key, key_events|
      # Use the richest attribute set (prefer entries with tax_identifier)
      best_attrs = key_events.sort_by { |e| e[:tax_identifier] ? 0 : 1 }.first

      # Walk through events chronologically and pair starts/ends
      open_stint = nil

      key_events.each do |event|
        if event[:type] == :start
          # Close any existing open stint at this date (re-appointment)
          if open_stint
            stints << open_stint
          end
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
            # Cessation without a prior designation — create a closed stint
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

      # If there's still an open stint, it's currently active
      stints << open_stint if open_stint
    end

    stints
  end

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

    # Mark any old roles from this source that are no longer in the stints as inactive
    stint_keys = stints.map { |s|
      person = find_person(entity, s)
      next unless person
      [ person.id, s[:role_type], s[:start_date] ]
    }.compact

    entity.entity_person_roles.where(active: true, source_name: SOURCE_NAME).includes(:person).find_each do |role|
      next if stint_keys.include?([ role.person_id, role.role_type, role.start_date ])
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
}
