# frozen_string_literal: true

namespace :flags do
  desc "Run the first scoring action (A2/A3 date-sequence anomaly)"
  task run_first_action: :environment do
    flagged = Flags::Actions::DateSequenceAnomalyAction.new.call
    puts "A2/A3 date-sequence anomalies flagged: #{flagged}"
  end

  desc "Run A9 price anomaly scoring (base vs effective price ratio)"
  task run_a9: :environment do
    flagged = Flags::Actions::PriceAnomalyAction.new.call
    puts "A9 price anomalies flagged: #{flagged}"
  end

  desc "Run A5 threshold splitting scoring (contract value just below thresholds)"
  task run_a5: :environment do
    flagged = Flags::Actions::ThresholdSplittingAction.new.call
    puts "A5 threshold splitting flagged: #{flagged}"
  end

  desc "Run A1 repeat direct award scoring (same authority + supplier within 36 months)"
  task run_a1: :environment do
    flagged = Flags::Actions::RepeatDirectAwardAction.new.call
    puts "A1 repeat direct awards flagged: #{flagged}"
  end

  desc "Run B5 Benford's Law deviation scoring (leading-digit distribution anomaly per entity)"
  task run_b5_benford: :environment do
    flagged = Flags::Actions::BenfordLawAction.new.call
    puts "B5 Benford's Law deviations flagged: #{flagged}"
  end

  desc "Run C1 missing winner NIF scoring (contracts with unidentified suppliers)"
  task run_c1: :environment do
    flagged = Flags::Actions::MissingWinnerNifAction.new.call
    puts "C1 missing winner NIF flagged: #{flagged}"
  end

  desc "Run C3 missing mandatory fields scoring (contracts lacking CPV, procedure type, or base price)"
  task run_c3: :environment do
    flagged = Flags::Actions::MissingMandatoryFieldsAction.new.call
    puts "C3 missing mandatory fields flagged: #{flagged}"
  end

  desc "Run B2 supplier concentration scoring (single supplier dominant share per authority)"
  task run_b2: :environment do
    flagged = Flags::Actions::SupplierConcentrationAction.new.call
    puts "B2 supplier concentration flagged: #{flagged}"
  end

  desc "Run all scoring actions"
  task run_all: :environment do
    %i[run_first_action run_a9 run_a5 run_a1 run_b5_benford run_c1 run_c3 run_b2].each do |t|
      Rake::Task["flags:#{t}"].invoke
    end
  end
end
