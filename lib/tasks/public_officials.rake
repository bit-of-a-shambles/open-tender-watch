# frozen_string_literal: true

require "csv"
require "json"

namespace :public_officials do
  desc "Import normalized Portuguese public-official roles from JSON or CSV (INPUT=path)"
  task import_roles: :environment do
    input = ENV.fetch("INPUT") { abort "Set INPUT to a JSON or CSV file" }
    abort "File not found: #{input}" unless File.exist?(input)

    records = if File.extname(input).downcase == ".csv"
      CSV.read(input, headers: true).map(&:to_h)
    else
      JSON.parse(File.read(input))
    end

    stats = PublicOfficials::PT::RoleImportService.new(records: records).call
    puts "Public-official roles imported: processed=#{stats.processed} updated=#{stats.updated} skipped=#{stats.skipped}"
  end

  desc "Refresh public-official to company-person identity match candidates"
  task match_people: :environment do
    stats = People::IdentityMatchService.new.call
    puts "Person identity matches refreshed: processed=#{stats[:processed]} upserted=#{stats[:upserted]}"
  end
end
