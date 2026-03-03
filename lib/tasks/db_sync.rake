# frozen_string_literal: true

# db:sync tasks — import large data sources locally where RAM is plentiful,
# then push the populated SQLite database up to the production server.
#
# Typical workflow:
#
#   bundle exec rails db:sync:import    # run Portal BASE import in development
#   bundle exec rails db:sync:push      # scp dev db → prod, reload app
#
# Or in one shot:
#   bundle exec rails db:sync:import_and_push

PROD_HOST    = "128.140.78.94"
PROD_DB_PATH = "storage/production.sqlite3"
LOCAL_DEV_DB = -> { ActiveRecord::Base.configurations.find_db_config("development").database }
BACKUP_STAMP = -> { Time.now.strftime("%Y%m%d_%H%M%S") }

namespace :db do
  namespace :sync do
    desc "Run Portal BASE import in development (safe — uses local RAM)"
    task import: :environment do
      abort "Run this in development: RAILS_ENV=development rails db:sync:import" unless Rails.env.development?

      puts "==> Running Portal BASE import in development..."
      Rake::Task["import:portal_base"].invoke
      puts "==> Import complete. Run 'rails db:sync:push' to upload to production."
    end

    desc "Push the development SQLite database to the production server"
    task push: :environment do
      abort "Run this in development: RAILS_ENV=development rails db:sync:push" unless Rails.env.development?

      dev_db = LOCAL_DEV_DB.call
      abort "Development database not found at #{dev_db}" unless File.exist?(dev_db)

      puts "==> Backing up production database..."
      backup_cmd = "ssh root@#{PROD_HOST} " \
        "'cp #{PROD_DB_PATH} #{PROD_DB_PATH}.bak_#{BACKUP_STAMP.call} 2>/dev/null || true'"
      system(backup_cmd)

      puts "==> Uploading #{dev_db} → #{PROD_HOST}:#{PROD_DB_PATH} ..."
      container_id_cmd = "ssh root@#{PROD_HOST} " \
        "\"docker ps --filter label=service=opentenderwatch -q | head -1\""
      container_id = `#{container_id_cmd}`.strip
      abort "Could not find running container on #{PROD_HOST}" if container_id.empty?

      # Copy to server tmp, then into the container volume
      system("scp #{dev_db} root@#{PROD_HOST}:/tmp/opentenderwatch_db_push.sqlite3")
      system("ssh root@#{PROD_HOST} " \
        "'docker cp /tmp/opentenderwatch_db_push.sqlite3 #{container_id}:#{PROD_DB_PATH} && " \
        "rm /tmp/opentenderwatch_db_push.sqlite3'")

      puts "==> Database pushed. Rebooting app..."
      system("bin/kamal app exec --reuse -- 'touch tmp/restart.txt' 2>/dev/null || bin/kamal app boot")
      puts "==> Done. Production database updated."
    end

    desc "Download the current production database to a local backup"
    task pull: :environment do
      abort "Run this in development" unless Rails.env.development?

      dest = Rails.root.join("tmp/production_pull_#{BACKUP_STAMP.call}.sqlite3")
      container_id = `ssh root@#{PROD_HOST} "docker ps --filter label=service=opentenderwatch -q | head -1"`.strip
      abort "Could not find running container" if container_id.empty?

      system("ssh root@#{PROD_HOST} 'docker cp #{container_id}:#{PROD_DB_PATH} /tmp/prod_pull.sqlite3'")
      system("scp root@#{PROD_HOST}:/tmp/prod_pull.sqlite3 #{dest}")
      system("ssh root@#{PROD_HOST} 'rm /tmp/prod_pull.sqlite3'")
      puts "==> Production database saved to #{dest}"
    end

    desc "Run Portal BASE import locally then push database to production"
    task import_and_push: [ "db:sync:import", "db:sync:push" ]
  end
end
