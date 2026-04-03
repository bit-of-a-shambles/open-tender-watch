# frozen_string_literal: true

module Flags
  module Actions
    # B3 — Unusual pricing relative to CPV-division × year peers
    #
    # Flags contracts whose base_price deviates significantly from the
    # statistical mean for contracts in the same CPV division (first 2 digits)
    # and publication year. A high positive z-score (expensive outlier) may
    # indicate price manipulation, over-scoping, or inflated estimates. A high
    # negative z-score (cheap outlier) may indicate a below-cost bid intended
    # to win then recoup via amendments.
    #
    # Peer group: contracts sharing the same 2-digit CPV division and the same
    # calendar year of publication_date. Groups with fewer than MIN_SAMPLE
    # contracts are skipped (insufficient statistical power).
    #
    # SQLite lacks a native STDDEV function. Population standard deviation is
    # computed as SQRT(E[X²] - E[X]²) which is algebraically equivalent and
    # numerically stable for this dataset.
    #
    # Two sub-flag types:
    #   B3_PRICE_HIGH — base_price is abnormally HIGH vs peers (z >= Z_MED)
    #   B3_PRICE_LOW  — base_price is abnormally LOW  vs peers (z <= -Z_MED)
    #
    # Severity:
    #   |z| >= Z_HIGH (3.5) → high (score 45)
    #   |z| >= Z_MED  (2.5) → medium (score 25)
    class PricingZScoreAction
      FLAG_HIGH  = "B3_PRICE_HIGH"
      FLAG_LOW   = "B3_PRICE_LOW"

      Z_MED      = 2.5   # |z| >= this → medium severity flag
      Z_HIGH     = 3.5   # |z| >= this → high severity flag

      SCORE_MED  = 25
      SCORE_HIGH = 45

      MIN_SAMPLE = 10    # minimum peer-group size for statistical validity
      MAX_FLAGS  = 100_000

      def call
        # Clean-slate: delete all existing B3 flags then rebuild.
        # Avoids an expensive WHERE NOT IN / stale-cleanup scan on a large table.
        Flag.where(flag_type: [ FLAG_HIGH, FLAG_LOW ]).delete_all

        rows      = outlier_contracts
        flag_rows = build_flag_rows(rows)

        Flag.upsert_all(flag_rows, unique_by: :index_flags_on_contract_id_and_flag_type) if flag_rows.any?

        flag_rows.size
      end

      private

      def outlier_contracts
        sql = <<~SQL
          WITH peer_stats AS (
            SELECT
              SUBSTR(cpv_code, 1, 2)                                       AS cpv_div,
              CAST(STRFTIME('%Y', publication_date) AS INTEGER)             AS pub_year,
              COUNT(*)                                                      AS peer_n,
              AVG(CAST(base_price AS FLOAT))                               AS peer_mean,
              SQRT(
                AVG(CAST(base_price AS FLOAT) * CAST(base_price AS FLOAT))
                - AVG(CAST(base_price AS FLOAT)) * AVG(CAST(base_price AS FLOAT))
              )                                                             AS peer_stddev
            FROM contracts
            WHERE base_price IS NOT NULL
              AND base_price > 0
              AND cpv_code IS NOT NULL
              AND publication_date IS NOT NULL
            GROUP BY
              SUBSTR(cpv_code, 1, 2),
              CAST(STRFTIME('%Y', publication_date) AS INTEGER)
            HAVING COUNT(*) >= #{MIN_SAMPLE}
              AND SQRT(
                    AVG(CAST(base_price AS FLOAT) * CAST(base_price AS FLOAT))
                    - AVG(CAST(base_price AS FLOAT)) * AVG(CAST(base_price AS FLOAT))
                  ) > 0
          )
          SELECT
            c.id                                                            AS contract_id,
            c.contracting_entity_id,
            c.base_price,
            ps.cpv_div,
            ps.pub_year,
            ps.peer_n,
            ROUND(ps.peer_mean,   2)                                       AS peer_mean,
            ROUND(ps.peer_stddev, 2)                                       AS peer_stddev,
            ROUND(
              (CAST(c.base_price AS FLOAT) - ps.peer_mean) / ps.peer_stddev,
              3
            )                                                               AS z_score
          FROM contracts c
          JOIN peer_stats ps
            ON  SUBSTR(c.cpv_code, 1, 2)                          = ps.cpv_div
            AND CAST(STRFTIME('%Y', c.publication_date) AS INTEGER) = ps.pub_year
          WHERE c.base_price IS NOT NULL
            AND c.base_price > 0
            AND c.cpv_code IS NOT NULL
            AND c.publication_date IS NOT NULL
            AND ABS(
                  (CAST(c.base_price AS FLOAT) - ps.peer_mean) / ps.peer_stddev
                ) >= #{Z_MED}
          ORDER BY
            ABS((CAST(c.base_price AS FLOAT) - ps.peer_mean) / ps.peer_stddev) DESC
          LIMIT #{MAX_FLAGS}
        SQL

        ApplicationRecord.connection.select_all(sql).to_a
      end

      def build_flag_rows(rows)
        now = Time.current
        rows.map do |r|
          z         = r["z_score"].to_f
          flag_type = z > 0 ? FLAG_HIGH : FLAG_LOW
          severity  = z.abs >= Z_HIGH ? "high" : "medium"
          score     = z.abs >= Z_HIGH ? SCORE_HIGH : SCORE_MED

          {
            contract_id: r["contract_id"],
            flag_type:   flag_type,
            severity:    severity,
            score:       score,
            details: {
              "z_score"     => z.round(3).to_s,
              "base_price"  => r["base_price"].to_s,
              "peer_mean"   => r["peer_mean"].to_s,
              "peer_stddev" => r["peer_stddev"].to_s,
              "peer_n"      => r["peer_n"].to_s,
              "cpv_div"     => r["cpv_div"].to_s,
              "pub_year"    => r["pub_year"].to_s,
              "rule"        => "B3 price z-score #{z.round(3)} " \
                               "(cpv_div=#{r["cpv_div"]}, year=#{r["pub_year"]}, " \
                               "peers=#{r["peer_n"]}, mean=#{r["peer_mean"]}, " \
                               "stddev=#{r["peer_stddev"]})"
            },
            fired_at:   now,
            created_at: now,
            updated_at: now
          }
        end
      end
    end
  end
end
