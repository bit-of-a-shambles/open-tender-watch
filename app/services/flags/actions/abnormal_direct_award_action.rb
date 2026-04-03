# frozen_string_literal: true

module Flags
  module Actions
    # A7 — Abnormal Direct Award Rate
    #
    # Flags direct-award contracts from authorities whose rate of using
    # "Ajuste Direto" significantly exceeds the peer median for the same
    # CPV division (first two digits of the CPV code).
    #
    # An authority+CPV-division pair is flagged when ALL of the following hold:
    #   1. The authority has >= MIN_AUTHORITY_CONTRACTS contracts in that division.
    #   2. Its direct award rate >= RATE_THRESHOLD (absolute ceiling, e.g. 80%).
    #   3. Its rate exceeds the CPV-division peer median by >= PEER_EXCESS pp.
    #
    # All direct-award contracts from flagged authority+CPV pairs are flagged,
    # capped at MAX_FLAGS to bound memory usage.
    #
    # Peer median is computed via the standard two-row window-function trick:
    #   SELECT AVG(rate) ... WHERE rn IN ((N+1)/2, (N+2)/2)
    # which returns the average of the middle one or two values (integer div).
    class AbnormalDirectAwardAction
      FLAG_TYPE               = "A7_ABNORMAL_DIRECT_AWARD_RATE"
      SCORE                   = 35
      SEVERITY                = "medium"
      MIN_AUTHORITY_CONTRACTS = 10
      RATE_THRESHOLD          = 0.80
      PEER_EXCESS             = 0.25
      MAX_FLAGS               = 50_000
      DIRECT_AWARD_PATTERN    = "%ajuste%"

      def call
        rows = flagged_contracts
        upsert_flags(rows)
        cleanup_stale_flags(rows.map { |r| r[:contract_id] })
        rows.size
      end

      private

      # Returns an array of hashes describing each direct-award contract that
      # belongs to a flagged (authority, CPV division) pair.
      def flagged_contracts
        sql = <<~SQL
          WITH cpv_groups AS (
            -- Per (authority, CPV division): direct-award count, total count, rate.
            -- Only include pairs with enough contracts to be statistically meaningful.
            SELECT
              contracting_entity_id,
              SUBSTR(cpv_code, 1, 2)                                              AS cpv_division,
              COUNT(*)                                                             AS total_count,
              SUM(CASE WHEN LOWER(procedure_type) LIKE '#{DIRECT_AWARD_PATTERN}'
                       THEN 1 ELSE 0 END)                                         AS direct_count,
              CAST(SUM(CASE WHEN LOWER(procedure_type) LIKE '#{DIRECT_AWARD_PATTERN}'
                            THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*)               AS direct_award_rate
            FROM contracts
            WHERE cpv_code IS NOT NULL AND cpv_code != ''
            GROUP BY contracting_entity_id, SUBSTR(cpv_code, 1, 2)
            HAVING COUNT(*) >= #{MIN_AUTHORITY_CONTRACTS}
          ),
          cpv_ranked AS (
            -- Assign ordered row numbers per CPV division for median calculation.
            SELECT
              cpv_division,
              direct_award_rate,
              ROW_NUMBER() OVER (PARTITION BY cpv_division
                                 ORDER BY direct_award_rate)        AS rn,
              COUNT(*)    OVER (PARTITION BY cpv_division)          AS cnt
            FROM cpv_groups
          ),
          cpv_medians AS (
            -- Standard two-row median trick (works for odd and even N).
            SELECT cpv_division, AVG(direct_award_rate) AS median_rate
            FROM cpv_ranked
            WHERE rn IN ((cnt + 1) / 2, (cnt + 2) / 2)
            GROUP BY cpv_division
          ),
          flagged_pairs AS (
            -- Identify (authority, CPV division) pairs that breach both thresholds.
            SELECT
              cg.contracting_entity_id,
              cg.cpv_division,
              cg.direct_award_rate,
              cg.direct_count,
              cg.total_count,
              cm.median_rate
            FROM cpv_groups cg
            JOIN cpv_medians cm ON cm.cpv_division = cg.cpv_division
            WHERE cg.direct_award_rate >= #{RATE_THRESHOLD}
              AND cg.direct_award_rate - cm.median_rate >= #{PEER_EXCESS}
          )
          -- Return all direct-award contracts from flagged pairs.
          SELECT
            c.id                                   AS contract_id,
            fp.contracting_entity_id               AS contracting_entity_id,
            fp.cpv_division                        AS cpv_division,
            ROUND(fp.direct_award_rate, 4)         AS direct_award_rate,
            ROUND(fp.median_rate, 4)               AS median_rate,
            fp.direct_count                        AS direct_count,
            fp.total_count                         AS total_count
          FROM contracts c
          JOIN flagged_pairs fp
            ON  fp.contracting_entity_id = c.contracting_entity_id
            AND fp.cpv_division           = SUBSTR(c.cpv_code, 1, 2)
          WHERE LOWER(c.procedure_type) LIKE '#{DIRECT_AWARD_PATTERN}'
            AND c.cpv_code IS NOT NULL AND c.cpv_code != ''
          ORDER BY fp.direct_award_rate DESC, c.id
          LIMIT #{MAX_FLAGS}
        SQL

        ActiveRecord::Base.connection.select_all(sql).map do |row|
          {
            contract_id:           row["contract_id"].to_i,
            contracting_entity_id: row["contracting_entity_id"].to_i,
            cpv_division:          row["cpv_division"].to_s,
            direct_award_rate:     row["direct_award_rate"].to_f.round(4),
            median_rate:           row["median_rate"].to_f.round(4),
            direct_count:          row["direct_count"].to_i,
            total_count:           row["total_count"].to_i
          }
        end
      end

      def upsert_flags(rows)
        return if rows.empty?

        now = Time.current
        flag_rows = rows.map do |r|
          {
            contract_id: r[:contract_id],
            flag_type:   FLAG_TYPE,
            severity:    SEVERITY,
            score:       SCORE,
            details: {
              "contracting_entity_id" => r[:contracting_entity_id],
              "cpv_division"          => r[:cpv_division],
              "direct_award_rate"     => r[:direct_award_rate].to_s,
              "peer_median_rate"      => r[:median_rate].to_s,
              "direct_count"          => r[:direct_count],
              "total_count"           => r[:total_count],
              "rule"                  => "A7 abnormal direct award rate: " \
                                        "#{(r[:direct_award_rate] * 100).round(1)}% vs " \
                                        "#{(r[:median_rate] * 100).round(1)}% CPV-division peer median"
            },
            fired_at:   now,
            created_at: now,
            updated_at: now
          }
        end

        Flag.upsert_all(flag_rows, unique_by: :index_flags_on_contract_id_and_flag_type)
      end

      def cleanup_stale_flags(live_ids)
        stale_scope = Flag.where(flag_type: FLAG_TYPE)
        if live_ids.empty?
          stale_scope.delete_all
        else
          stale_scope.where.not(contract_id: live_ids).delete_all
        end
      end
    end
  end
end
