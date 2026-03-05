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

  # ---------------------------------------------------------------------------
  # Aggregation — pre-compute materialized stats so the dashboard never has to
  # run expensive joins across 2M+ flags at request time.
  # ---------------------------------------------------------------------------
  desc "Aggregate flag stats into pre-computed tables (flag_entity_stats + flag_summary_stats)"
  task aggregate: :environment do
    puts "Aggregating flag entity stats…"
    conn = ActiveRecord::Base.connection
    now  = Time.current.utc.strftime("%Y-%m-%d %H:%M:%S")

    # Use total_effective_price (actual awarded value) where available; fall back
    # to base_price only when null/zero.  base_price is the framework envelope
    # ceiling and can be wildly inflated (e.g. €147B for a single drug purchase).
    price_expr = "COALESCE(NULLIF(c.total_effective_price, 0), c.base_price)"

    conn.transaction do
      # -----------------------------------------------------------------------
      # flag_entity_stats — one row per (entity, flag_type, severity).
      # Counts distinct contracts and sums their effective price, grouped by
      # contracting entity.
      # -----------------------------------------------------------------------
      conn.execute("DELETE FROM flag_entity_stats")
      conn.execute(<<~SQL)
        INSERT INTO flag_entity_stats
          (entity_id, flag_type, severity, total_exposure, contract_count,
           computed_at, created_at, updated_at)
        SELECT
          c.contracting_entity_id                          AS entity_id,
          f.flag_type,
          f.severity,
          COALESCE(SUM(#{price_expr}), 0)                  AS total_exposure,
          COUNT(DISTINCT f.contract_id)                    AS contract_count,
          '#{now}', '#{now}', '#{now}'
        FROM (SELECT DISTINCT contract_id, flag_type, severity FROM flags) f
        JOIN contracts c ON c.id = f.contract_id
        GROUP BY c.contracting_entity_id, f.flag_type, f.severity
      SQL

      entity_rows = conn.select_value("SELECT COUNT(*) FROM flag_entity_stats")
      puts "  entity stats rows: #{entity_rows}"

      # -----------------------------------------------------------------------
      # flag_summary_stats — one row per severity variant (NULL + high/medium/low).
      # Stores the deduplicated totals used by the dashboard sidebar.
      # -----------------------------------------------------------------------
      conn.execute("DELETE FROM flag_summary_stats")

      [nil, "high", "medium", "low"].each do |sev|
        sev_filter = sev ? "WHERE f.severity = '#{sev}'" : ""
        sev_val    = sev ? "'#{sev}'" : "NULL"

        total_exposure = conn.select_value(<<~SQL).to_f
          SELECT COALESCE(SUM(COALESCE(NULLIF(c.total_effective_price, 0), c.base_price)), 0)
          FROM contracts c
          WHERE c.id IN (SELECT DISTINCT f.contract_id FROM flags f #{sev_filter})
        SQL

        flagged_contracts = conn.select_value(<<~SQL).to_i
          SELECT COUNT(DISTINCT f.contract_id) FROM flags f #{sev_filter}
        SQL

        companies = conn.select_value(<<~SQL).to_i
          SELECT COUNT(DISTINCT cw.entity_id)
          FROM flags f
          JOIN contract_winners cw ON cw.contract_id = f.contract_id
          JOIN entities e ON e.id = cw.entity_id
          #{sev_filter.empty? ? "WHERE" : sev_filter + " AND"} e.is_company = 1
        SQL

        public_entities = conn.select_value(<<~SQL).to_i
          SELECT COUNT(DISTINCT c.contracting_entity_id)
          FROM flags f
          JOIN contracts c ON c.id = f.contract_id
          JOIN entities e ON e.id = c.contracting_entity_id
          #{sev_filter.empty? ? "WHERE" : sev_filter + " AND"} e.is_public_body = 1
        SQL

        conn.execute(<<~SQL)
          INSERT INTO flag_summary_stats
            (severity, total_exposure, flagged_contract_count,
             flagged_companies_count, flagged_public_entities_count,
             computed_at, created_at, updated_at)
          VALUES (
            #{sev_val},
            #{total_exposure},
            #{flagged_contracts},
            #{companies},
            #{public_entities},
            '#{now}', '#{now}', '#{now}'
          )
        SQL

        puts "  severity=#{sev || 'nil'}: exposure=#{total_exposure.round} contracts=#{flagged_contracts} companies=#{companies} public=#{public_entities}"
      end
    end

    puts "Aggregation complete."
  end

  desc "Run all scoring actions then aggregate stats"
  task run_all: :environment do
    %i[run_first_action run_a9 run_a5 run_a1 run_b5_benford run_c1 run_c3 run_b2 aggregate].each do |t|
      Rake::Task["flags:#{t}"].invoke
    end
  end
end
