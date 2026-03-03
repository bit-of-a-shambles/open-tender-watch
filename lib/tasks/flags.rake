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

  desc "Run all scoring actions"
  task run_all: :environment do
    %i[run_first_action run_a9 run_a5 run_a1].each do |t|
      Rake::Task["flags:#{t}"].invoke
    end
  end
end
