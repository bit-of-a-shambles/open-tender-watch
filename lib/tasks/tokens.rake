# frozen_string_literal: true

namespace :tokens do
  desc "Generate a new access token. Usage: rails tokens:generate[name,organisation,level]"
  task :generate, [ :name, :organisation, :level ] => :environment do |_t, args|
    name = args[:name]
    organisation = args[:organisation] || ""
    level = args[:level] || "journalist"

    unless name.present?
      puts "Usage: rails tokens:generate[name,organisation,level]"
      puts "  name:         required — identifier for the token holder"
      puts "  organisation: optional — e.g. 'Público', 'Tribunal de Contas'"
      puts "  level:        optional — 'journalist' (default) or 'auditor'"
      exit 1
    end

    token = AccessToken.create!(
      name: name,
      organisation: organisation,
      access_level: level
    )

    puts "Token created:"
    puts "  Name:         #{token.name}"
    puts "  Organisation: #{token.organisation}"
    puts "  Level:        #{token.access_level}"
    puts "  Token:        #{token.token}"
    puts ""
    puts "Share this token securely with the recipient."
  end

  desc "List all access tokens"
  task list: :environment do
    tokens = AccessToken.order(created_at: :desc)
    if tokens.empty?
      puts "No tokens found."
    else
      puts format("%-20s %-20s %-12s %-8s %-20s", "Name", "Organisation", "Level", "Uses", "Last used")
      puts "-" * 84
      tokens.each do |t|
        puts format("%-20s %-20s %-12s %-8d %-20s",
          t.name.truncate(18),
          t.organisation.to_s.truncate(18),
          t.access_level,
          t.usage_count,
          t.last_used_at&.strftime("%Y-%m-%d %H:%M") || "never")
      end
    end
  end

  desc "Revoke an access token by name"
  task :revoke, [ :name ] => :environment do |_t, args|
    token = AccessToken.find_by(name: args[:name])
    if token
      token.update!(expires_at: Time.current)
      puts "Token '#{token.name}' revoked (expired)."
    else
      puts "Token '#{args[:name]}' not found."
    end
  end
end
