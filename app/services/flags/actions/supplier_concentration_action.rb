# frozen_string_literal: true

module Flags
  module Actions
    # B2 — Supplier concentration (Herfindahl-style)
    #
    # Flags contracts where a single supplier received an abnormally high share
    # of a contracting authority's awards. When one vendor captures >= 70% of
    # all contracts from an authority (with at least 5 contracts and at least
    # 3 going to that winner), it may indicate bid rotation, relationship
    # dependency, or capture.
    #
    # Only processes the top MAX_FLAGS contracts by concentration ratio to
    # avoid memory pressure on large datasets.
    class SupplierConcentrationAction
      FLAG_TYPE               = "B2_SUPPLIER_CONCENTRATION"
      SCORE                   = 45
      SEVERITY                = "high"
      MIN_AUTHORITY_CONTRACTS = 5
      MIN_WINNER_CONTRACTS    = 3
      CONCENTRATION_THRESHOLD = 0.70
      MAX_FLAGS               = 10_000

      def call
        rows = concentrated_contracts
        upsert_flags(rows)
        cleanup_stale_flags(rows.map { |r| r[:contract_id] })
        rows.size
      end

      private

      # Returns array of hashes:
      # { contract_id:, winner_id:, contracting_entity_id:, ratio:,
      #   winner_count:, total_count: }
      # Capped at MAX_FLAGS rows.
      def concentrated_contracts
        sql = <<~SQL
          WITH authority_totals AS (
            SELECT contracting_entity_id, COUNT(*) AS total_count
            FROM contracts
            GROUP BY contracting_entity_id
            HAVING COUNT(*) >= #{MIN_AUTHORITY_CONTRACTS}
          ),
          winner_counts AS (
            SELECT c.contracting_entity_id,
                   cw.entity_id         AS winner_id,
                   COUNT(*)             AS winner_count
            FROM contracts c
            JOIN contract_winners cw ON cw.contract_id = c.id
            GROUP BY c.contracting_entity_id, cw.entity_id
            HAVING COUNT(*) >= #{MIN_WINNER_CONTRACTS}
          ),
          concentrated_pairs AS (
            SELECT wc.contracting_entity_id,
                   wc.winner_id,
                   wc.winner_count,
                   at.total_count,
                   CAST(wc.winner_count AS FLOAT) / at.total_count AS ratio
            FROM winner_counts wc
            JOIN authority_totals at
              ON at.contracting_entity_id = wc.contracting_entity_id
            WHERE CAST(wc.winner_count AS FLOAT) / at.total_count
                    >= #{CONCENTRATION_THRESHOLD}
          )
          SELECT c.id                            AS contract_id,
                 cp.winner_id                    AS winner_id,
                 cp.contracting_entity_id        AS contracting_entity_id,
                 ROUND(cp.ratio, 4)              AS ratio,
                 cp.winner_count                 AS winner_count,
                 cp.total_count                  AS total_count
          FROM contracts c
          JOIN contract_winners cw
            ON cw.contract_id = c.id
          JOIN concentrated_pairs cp
            ON cp.contracting_entity_id = c.contracting_entity_id
           AND cp.winner_id             = cw.entity_id
          ORDER BY cp.ratio DESC, cp.winner_count DESC
          LIMIT #{MAX_FLAGS}
        SQL

        ActiveRecord::Base.connection.select_all(sql).map do |row|
          {
            contract_id:            row["contract_id"].to_i,
            winner_id:              row["winner_id"].to_i,
            contracting_entity_id:  row["contracting_entity_id"].to_i,
            ratio:                  row["ratio"].to_f.round(4),
            winner_count:           row["winner_count"].to_i,
            total_count:            row["total_count"].to_i
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
              "winner_entity_id"       => r[:winner_id],
              "contracting_entity_id"  => r[:contracting_entity_id],
              "concentration_ratio"    => r[:ratio].to_s,
              "winner_contract_count"  => r[:winner_count],
              "authority_total_count"  => r[:total_count],
              "rule"                   => "B2 supplier concentration: winner holds " \
                                         "#{(r[:ratio] * 100).round(1)}% of authority contracts"
            },
            fired_at:   now,
            created_at: now,
            updated_at: now
          }
        end

        Flag.upsert_all(flag_rows, unique_by: :index_flags_on_contract_id_and_flag_type)
      end

      def cleanup_stale_flags(flagged_ids)
        stale_scope = Flag.where(flag_type: FLAG_TYPE)
        if flagged_ids.empty?
          stale_scope.delete_all
        else
          stale_scope.where.not(contract_id: flagged_ids).delete_all
        end
      end
    end
  end
end
