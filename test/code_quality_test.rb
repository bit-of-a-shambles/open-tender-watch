# frozen_string_literal: true

require "test_helper"

# Structural checks that catch known performance and correctness anti-patterns
# before they reach production. These supplement unit tests — they inspect
# source files directly so bad patterns fail the suite at commit time.
class CodeQualityTest < ActiveSupport::TestCase
  # Scan controllers and services for SQL anti-patterns.
  SOURCE_DIRS = %w[app/controllers app/services].freeze

  # IN (subquery) on the flags table materialises millions of rows (>1M for A2
  # alone). Always use EXISTS instead — correlated EXISTS short-circuits on
  # first match and uses the (contract_id, flag_type) composite index directly.
  #
  # Bad:   contracts.id IN (SELECT contract_id FROM flags WHERE flag_type = ?)
  # Good:  EXISTS (SELECT 1 FROM flags f WHERE f.contract_id = contracts.id AND f.flag_type = ?)
  test "no IN subquery on flags table in controllers or services" do
    offenders = []

    SOURCE_DIRS.each do |dir|
      Dir[Rails.root.join(dir, "**", "*.rb")].each do |file|
        content = File.read(file)
        if content.match?(/IN\s*\(SELECT.*FROM\s+flags/i)
          relative = file.sub("#{Rails.root}/", "")
          offenders << relative
        end
      end
    end

    assert offenders.empty?,
      "Found IN (subquery) on flags table — use EXISTS instead:\n  #{offenders.join("\n  ")}"
  end

  # GROUP BY + JOIN contract_winners to aggregate won_count / won_value per
  # entity causes a full table scan of contract_winners (millions of rows) on
  # every request.  Use the pre-computed won_contract_count / won_value columns
  # on entities instead (maintained by Entities::UpdateStatsService).
  #
  # Bad:   .joins("LEFT JOIN contract_winners ...").joins("LEFT JOIN contracts ...").group("entities.id").select("COUNT(...) AS won_count, SUM(...) AS won_value")
  # Good:  .select("entities.won_contract_count AS won_count, entities.won_value")
  test "no GROUP BY over contract_winners join in controllers" do
    offenders = []

    Dir[Rails.root.join("app/controllers/**/*.rb")].each do |file|
      content = File.read(file)
      # Flag any file that both JOINs contract_winners AND uses GROUP BY
      if content.include?("contract_winners") && content.match?(/\.group\s*\(.*entities\.id/i)
        offenders << file.sub("#{Rails.root}/", "")
      end
    end

    assert offenders.empty?,
      "Found GROUP BY over contract_winners join in controllers — use pre-computed won_contract_count/won_value on entities:\n  #{offenders.join("\n  ")}"
  end
end
