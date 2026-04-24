# frozen_string_literal: true

namespace :enrich do
  desc "Export target NIFs ordered by flagged exposure (OUTPUT=path, SKIP_ENRICHED=1, LIMIT=N)"
  task export_nifs: :environment do
    skip_enriched = ENV.fetch("SKIP_ENRICHED", "1") == "1"
    limit = ENV["LIMIT"]&.to_i
    output = ENV.fetch("OUTPUT", "/tmp/rc_target_nifs.txt")

    # Phase 1: flagged companies ordered by total exposure DESC
    flagged_ids = Entity
      .where(country_code: "PT", is_company: true)
      .joins(:flag_entity_stats)
      .select("entities.id, SUM(flag_entity_stats.total_exposure) AS exposure")
      .group("entities.id")
      .order(Arel.sql("SUM(flag_entity_stats.total_exposure) DESC"))
      .map(&:id)

    # Phase 2: remaining companies ordered by won_value DESC
    remaining_ids = Entity
      .where(country_code: "PT", is_company: true)
      .where.not(id: flagged_ids)
      .order(won_value: :desc)
      .pluck(:id)

    all_ids = flagged_ids + remaining_ids

    if skip_enriched
      already_done = EntityPersonRole.where(active: true).distinct.pluck(:entity_id).to_set
      before = all_ids.size
      all_ids.reject! { |id| already_done.include?(id) }
      puts "Skipping #{before - all_ids.size} already-enriched entities"
    end

    all_ids = all_ids.first(limit) if limit

    nifs = Entity.where(id: all_ids).index_by(&:id)
    ordered_nifs = all_ids.filter_map { |id| nifs[id]&.tax_identifier }

    File.write(output, ordered_nifs.join("\n") + "\n")
    puts "Exported #{ordered_nifs.size} NIFs to #{output} (#{flagged_ids.size} flagged first)"
  end

  desc "Harvest Registo Comercial via Ferrum + 2Captcha, importing into DB as each NIF completes (TWOCAPTCHA_KEY=, NIFS_FILE=, BATCH=, OUTPUT=, HEADLESS=)"
  task harvest: :environment do
    captcha_key = ENV.fetch("TWOCAPTCHA_KEY") { abort "Set TWOCAPTCHA_KEY environment variable" }
    output = ENV.fetch("OUTPUT", "/tmp/rc_results.json")
    headless = ENV.fetch("HEADLESS", "false") == "true"
    batch = ENV["BATCH"]&.to_i
    nifs_file = ENV["NIFS_FILE"]

    if nifs_file
      abort "File not found: #{nifs_file}" unless File.exist?(nifs_file)
      nifs = File.readlines(nifs_file).map(&:strip).reject(&:empty?)
    else
      # Default: export flagged NIFs inline
      Rake::Task["enrich:export_nifs"].invoke
      nifs = File.readlines("/tmp/rc_target_nifs.txt").map(&:strip).reject(&:empty?)
    end

    nifs = nifs.first(batch) if batch

    importer = PublicContracts::PT::RegistoComercialImporter.new
    db_stats = { processed: 0, updated: 0, skipped: 0, roles_created: 0 }

    on_nif_complete = ->(nif, nif_data) {
      result = importer.import_nif(nif, nif_data)
      db_stats[:processed] += result.processed
      db_stats[:updated] += result.updated
      db_stats[:skipped] += result.skipped
      db_stats[:roles_created] += result.roles_created

      if result.updated > 0
        puts "  💾 DB: #{nif} imported (#{result.roles_created} roles)"
      end
    }

    harvester = PublicContracts::PT::RegistoComercialHarvester.new(
      captcha_key: captcha_key,
      output_path: output,
      headless: headless,
      on_nif_complete: on_nif_complete
    )
    harvester.harvest(nifs)

    puts "\nDB import totals: #{db_stats}"
  end

  desc "Import harvested Registo Comercial JSON into the database (INPUT=path)"
  task import_rc: :environment do
    input = ENV.fetch("INPUT", "/tmp/rc_results.json")
    abort "File not found: #{input}" unless File.exist?(input)

    importer = PublicContracts::PT::RegistoComercialImporter.new
    stats = importer.import_file(input)
    puts "Done: processed=#{stats.processed} updated=#{stats.updated} skipped=#{stats.skipped} roles_created=#{stats.roles_created}"
  end
end
