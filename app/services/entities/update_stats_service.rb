# frozen_string_literal: true

module Entities
  # Refreshes the pre-computed contract_count and total_contracted_value columns
  # on the entities table. Called:
  #   - After every import run (ImportService#call / call_all / call_streaming)
  #   - After every dedup run (dedup rake tasks)
  #   - After the flag scoring cycle (flags:run_all)
  #
  # A single UPDATE … SET … = (SELECT …) is much faster than loading all
  # entities into Ruby and calling #update! on each one.
  #
  # Price logic (three-tier):
  #   1. Use total_effective_price when available (actual awarded amount).
  #   2. When missing, divide base_price by the winner count — each supplier's
  #      allocated share of the framework ceiling.
  #   3. When no winners at all, use 0 — the contract hasn't been awarded yet.
  # Using raw base_price multiplies the framework ceiling across every winner
  # row, producing wildly inflated totals (e.g. €315M × 12 suppliers = €3.78B
  # for a single framework agreement).
  class UpdateStatsService
    def call
      ApplicationRecord.connection.execute(<<~SQL)
        WITH winner_counts AS (
          SELECT contract_id, COUNT(*) AS cnt
          FROM contract_winners
          GROUP BY contract_id
        ),
        entity_sums AS (
          SELECT
            c.contracting_entity_id                 AS entity_id,
            COUNT(*)                                AS contract_cnt,
            COALESCE(SUM(
              CASE
                WHEN c.total_effective_price > 0 THEN c.total_effective_price
                WHEN wc.cnt IS NOT NULL           THEN c.base_price / wc.cnt
                ELSE 0
              END
            ), 0)                                   AS total_val
          FROM contracts c
          LEFT JOIN winner_counts wc ON wc.contract_id = c.id
          GROUP BY c.contracting_entity_id
        )
        UPDATE entities
        SET
          contract_count = COALESCE(
            (SELECT contract_cnt FROM entity_sums WHERE entity_sums.entity_id = entities.id),
            0
          ),
          total_contracted_value = COALESCE(
            (SELECT total_val FROM entity_sums WHERE entity_sums.entity_id = entities.id),
            0
          )
      SQL

      # Compute won_contract_count and won_value for private entities (contract
      # winners).  Uses the same simple SUM(base_price) shown in the companies
      # index — sufficient for ranking; adjust to three-tier logic if needed.
      ApplicationRecord.connection.execute(<<~SQL)
        WITH winner_sums AS (
          SELECT
            cw.entity_id,
            COUNT(*)                    AS won_cnt,
            COALESCE(SUM(c.base_price), 0) AS won_val
          FROM contract_winners cw
          JOIN contracts c ON c.id = cw.contract_id
          GROUP BY cw.entity_id
        )
        UPDATE entities
        SET
          won_contract_count = COALESCE(
            (SELECT won_cnt FROM winner_sums WHERE winner_sums.entity_id = entities.id),
            0
          ),
          won_value = COALESCE(
            (SELECT won_val FROM winner_sums WHERE winner_sums.entity_id = entities.id),
            0
          )
      SQL

      true
    end
  end
end
