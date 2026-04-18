# frozen_string_literal: true

namespace :import do
  desc "Import one page from every active DataSource (fast smoke-test)"
  task once: :environment do
    DataSource.active.each do |ds|
      puts "  #{ds.adapter_class}..."
      PublicContracts::ImportService.new(ds).call
      puts "    #{ds.reload.record_count} records, status: #{ds.status}"
    end
  end

  desc "Paginate and import ALL records from a specific adapter (or all if omitted)"
  task :all, [ :adapter ] => :environment do |_, args|
    sources = if args[:adapter].present?
      DataSource.where(adapter_class: args[:adapter])
    else
      DataSource.active
    end

    sources.each do |ds|
      puts "\n[#{ds.adapter_class}]"
      PublicContracts::ImportService.new(ds).call_all
      puts "  status: #{ds.reload.status}, total: #{ds.record_count}"
    end
  end

  desc "Import all SNS health-sector contracts (~43K records)"
  task sns: :environment do
    ds = DataSource.find_by!(adapter_class: "PublicContracts::PT::SnsClient")
    puts "Starting SNS full import. Total available: #{ds.adapter.total_count}"
    PublicContracts::ImportService.new(ds).call_all
    puts "Finished. Contracts in DB: #{Contract.where(data_source: ds).count}"
  end

  desc "Import all TED EU procurement notices for the configured country"
  task ted: :environment do
    ds = DataSource.find_by!(adapter_class: "PublicContracts::EU::TedClient")
    puts "Starting TED full import. Total available: #{ds.adapter.total_count}"
    PublicContracts::ImportService.new(ds).call_all
    puts "Finished. Contracts in DB: #{Contract.where(data_source: ds).count}"
  end

  desc "Import all QuemFatura.pt contracts (~23K records). Requires cf_clearance in DataSource config."
  task quem_fatura: :environment do
    ds = DataSource.find_by!(adapter_class: "PublicContracts::PT::QuemFaturaClient")
    puts "Starting QuemFatura.pt full import. Total available: #{ds.adapter.total_count}"
    PublicContracts::ImportService.new(ds).call_all
    puts "Finished. Contracts in DB: #{Contract.where(data_source: ds).count}"
  end

  desc "Import Portal BASE contracts from dados.gov.pt (optionally scope with YEARS=2024,2025,2026 and BATCH_SIZE=1000)"
  task portal_base: :environment do
    ds      = DataSource.find_by!(adapter_class: "PublicContracts::PT::PortalBaseClient")
    years_override = ENV["YEARS"]&.split(",")&.filter_map { |value| Integer(value.strip, exception: false) }
    batch_size = Integer(ENV.fetch("BATCH_SIZE", 1000), exception: false) || 1000
    batch_size = 1000 if batch_size <= 0
    adapter = if years_override.present?
      PublicContracts::PT::PortalBaseClient.new(ds.config.merge("years" => years_override))
    else
      ds.adapter
    end
    years   = adapter.instance_variable_get(:@years)

    puts "Portal BASE import — #{years.size} year file(s): #{years.join(', ')}"
    puts

    # Phase 1: download all source files to disk cache
    puts "Phase 1/2: Downloading source files..."
    t_dl = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    adapter.prefetch_files { |msg| puts msg }
    dl_elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_dl).round(1)
    puts "  All files ready in #{dl_elapsed}s."
    puts

    # Phase 2: import from cache
    estimated = adapter.total_count
    puts "Phase 2/2: Importing rows from cache..."
    puts "  Estimated rows : ~#{estimated.to_s.reverse.scan(/.{1,3}/).join(',').reverse}"
    puts "  Mode           : #{adapter.respond_to?(:each_contract) ? 'streaming (single-pass, entity-cached)' : 'paginated'}"
    puts "  Batch size     : #{batch_size}"

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ds.define_singleton_method(:adapter) { adapter }
    PublicContracts::ImportService.new(ds).call_all(limit: batch_size)
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(1)

    count = Contract.where(data_source: ds).count
    puts "Finished in #{elapsed}s. Contracts in DB: #{count.to_s.reverse.scan(/.{1,3}/).join(',').reverse}"
  end
end
