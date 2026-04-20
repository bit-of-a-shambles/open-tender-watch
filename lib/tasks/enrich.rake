# frozen_string_literal: true

namespace :enrich do
  desc "Enrich company people roles from Registo Comercial (NIF=..., INPUT=..., LIMIT=..., OFFSET=...)"
  task company_people: :environment do
    stats = PublicContracts::EntityPeopleEnrichmentService.new.call(
      nif: ENV["NIF"],
      input: ENV["INPUT"],
      limit: ENV["LIMIT"],
      offset: ENV["OFFSET"]
    )

    puts "Processed: #{stats[:processed]}"
    puts "Updated:   #{stats[:updated]}"
    puts "Skipped:   #{stats[:skipped]}"
  end

  desc "Enrich all PT companies ordered by flagged exposure (SKIP_ENRICHED=1 to skip already-done)"
  task company_people_by_risk: :environment do
    skip_enriched = ENV.fetch("SKIP_ENRICHED", "1") == "1"
    limit = ENV["LIMIT"]&.to_i

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

    total = all_ids.size
    puts "Enriching #{total} companies (#{flagged_ids.size} flagged first)"
    puts "Started at #{Time.current.strftime('%H:%M:%S')}"

    service = PublicContracts::EntityPeopleEnrichmentService.new
    stats = { processed: 0, updated: 0, skipped: 0, errors: 0 }
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    all_ids.each_with_index do |entity_id, index|
      entity = Entity.find(entity_id)
      stats[:processed] += 1

      begin
        if service.enrich_entity(entity)
          stats[:updated] += 1
        else
          stats[:skipped] += 1
        end
      rescue => e
        stats[:errors] += 1
        $stderr.puts "  ERROR #{entity.tax_identifier} (#{entity.name}): #{e.message}"
      end

      if (index + 1) % 25 == 0 || index + 1 == total
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        rate = (index + 1) / elapsed
        eta_seconds = ((total - index - 1) / rate).round
        eta_h, eta_m = eta_seconds.divmod(3600).then { |h, r| [h, r / 60] }
        puts "[#{Time.current.strftime('%H:%M:%S')}] " \
             "#{index + 1}/#{total} " \
             "(#{stats[:updated]} found, #{stats[:skipped]} empty, #{stats[:errors]} errors) " \
             "ETA: #{eta_h}h#{eta_m}m"
      end
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
    puts "\nDone in #{(elapsed / 60).round}m — " \
         "processed: #{stats[:processed]}, updated: #{stats[:updated]}, " \
         "skipped: #{stats[:skipped]}, errors: #{stats[:errors]}"
  end
end
