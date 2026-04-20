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
end
