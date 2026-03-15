# frozen_string_literal: true

module Flags
  # Populates flag_entity_stats and flag_summary_stats from the flags + contracts
  # tables. Called from flags:aggregate rake task and from tests.
  #
  # This pre-computation is what lets the dashboard respond in milliseconds even
  # when the flags table has millions of rows. Run this after every flag-scoring
  # cycle (i.e. at the end of flags:run_all).
  class AggregateStatsService
    def call
      conn = ActiveRecord::Base.connection
      now  = Time.current.utc.strftime("%Y-%m-%d %H:%M:%S")

      conn.transaction do
        aggregate_entity_stats(conn, now)
        aggregate_summary_stats(conn, now)
      end

      true
    end

    private

    # One row per (entity_id, flag_type, severity) — pre-aggregated from flags JOIN contracts.
    #
    # B5 (Benford) is special: a single representative contract is flagged per
    # entity, but the meaningful metric is the whole entity's distribution.
    # We therefore use benford_analyses.sample_size as contract_count and
    # entities.total_contracted_value as total_exposure for B5 rows, and handle
    # all other flags with the standard contract-level aggregation.
    #
    # Three-tier price logic — see flags.rake price_case for explanation.
    def aggregate_entity_stats(conn, now)
      conn.execute("DELETE FROM flag_entity_stats")

      # Standard flags — one flag row maps to one contract.
      conn.execute(<<~SQL)
        WITH winner_counts AS (
          SELECT contract_id, COUNT(*) AS cnt
          FROM contract_winners
          GROUP BY contract_id
        )
        INSERT INTO flag_entity_stats
          (entity_id, flag_type, severity, total_exposure, contract_count,
           computed_at, created_at, updated_at)
        SELECT
          c.contracting_entity_id        AS entity_id,
          f.flag_type,
          f.severity,
          COALESCE(SUM(
            CASE
              WHEN c.total_effective_price > 0 THEN c.total_effective_price
              WHEN wc.cnt IS NOT NULL           THEN c.base_price / wc.cnt
              ELSE 0
            END
          ), 0) AS total_exposure,
          COUNT(*)                        AS contract_count,
          '#{now}', '#{now}', '#{now}'
        FROM flags f
        JOIN contracts c ON c.id = f.contract_id
        LEFT JOIN winner_counts wc ON wc.contract_id = c.id
        WHERE f.flag_type != 'B5_BENFORD_DEVIATION'
        GROUP BY c.contracting_entity_id, f.flag_type, f.severity
      SQL

      # B5 Benford: one flag per entity flagged, but count = full sample size
      # and exposure = entity's total contracted value.
      conn.execute(<<~SQL)
        INSERT INTO flag_entity_stats
          (entity_id, flag_type, severity, total_exposure, contract_count,
           computed_at, created_at, updated_at)
        SELECT
          ba.entity_id,
          'B5_BENFORD_DEVIATION'            AS flag_type,
          f.severity,
          COALESCE(e.total_contracted_value, 0) AS total_exposure,
          ba.sample_size                    AS contract_count,
          '#{now}', '#{now}', '#{now}'
        FROM benford_analyses ba
        JOIN flags f
          ON f.contract_id = ba.representative_contract_id
         AND f.flag_type   = 'B5_BENFORD_DEVIATION'
        JOIN entities e ON e.id = ba.entity_id
        WHERE ba.flagged = 1
      SQL
    end

    # One row per severity variant (NULL + high/medium/low) with deduplicated totals.
    def aggregate_summary_stats(conn, now)
      conn.execute("DELETE FROM flag_summary_stats")

      [nil, "high", "medium", "low"].each do |sev|
        sev_where = sev ? "WHERE f.severity = #{conn.quote(sev)}" : ""
        sev_and   = sev ? "AND f.severity = #{conn.quote(sev)}"   : ""
        sev_val   = conn.quote(sev)

        total_exposure = conn.select_value(<<~SQL).to_f
          WITH winner_counts AS (
            SELECT contract_id, COUNT(*) AS cnt
            FROM contract_winners
            GROUP BY contract_id
          )
          SELECT COALESCE(SUM(
            CASE
              WHEN c.total_effective_price > 0 THEN c.total_effective_price
              WHEN wc.cnt IS NOT NULL           THEN c.base_price / wc.cnt
              ELSE 0
            END
          ), 0)
          FROM contracts c
          LEFT JOIN winner_counts wc ON wc.contract_id = c.id
          WHERE EXISTS (SELECT 1 FROM flags f WHERE f.contract_id = c.id #{sev_and})
        SQL

        flagged_contracts = conn.select_value(<<~SQL).to_i
          SELECT COUNT(DISTINCT f.contract_id) FROM flags f #{sev_where}
        SQL

        companies = conn.select_value(<<~SQL).to_i
          SELECT COUNT(DISTINCT cw.entity_id)
          FROM flags f
          JOIN contract_winners cw ON cw.contract_id = f.contract_id
          JOIN entities e ON e.id = cw.entity_id
          WHERE e.is_company = 1 #{sev_and}
        SQL

        public_entities = conn.select_value(<<~SQL).to_i
          SELECT COUNT(DISTINCT c.contracting_entity_id)
          FROM flags f
          JOIN contracts c ON c.id = f.contract_id
          JOIN entities e ON e.id = c.contracting_entity_id
          WHERE e.is_public_body = 1 #{sev_and}
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
      end
    end
  end
end
