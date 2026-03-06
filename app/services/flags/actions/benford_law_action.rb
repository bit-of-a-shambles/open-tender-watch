# frozen_string_literal: true

module Flags
  module Actions
    # B5 — Benford's Law deviation
    #
    # In naturally occurring financial data the leading digit d appears with
    # probability P(d) = log10(1 + 1/d). When a contracting entity's contract
    # amounts deviate significantly from this distribution it may indicate price
    # manipulation, rounding to avoid thresholds, or fabrication.
    #
    # Algorithm:
    #   1. Pre-filter: only entities with contract_count >= MIN_SAMPLE are
    #      processed (uses the pre-computed column — skips ~95% of entities).
    #   2. Batch-process eligible entities in groups of BATCH_SIZE.
    #   3. For each batch: fetch digit counts scoped to those entity IDs.
    #   4. Compute chi-square goodness-of-fit statistic (df = 8).
    #   5. Write BenfordAnalysis rows for ALL eligible entities — flagged or not
    #      — so digit distributions are available for future visualizations.
    #   6. Write Flag rows only for anomalous entities (chi2 >= CHI2_P05).
    #
    # One representative contract is flagged per entity: the highest-value
    # awarded contract (celebration_date NOT NULL); falls back to highest
    # base_price if no awarded contract exists.
    class BenfordLawAction
      FLAG_TYPE   = "B5_BENFORD_DEVIATION"
      MIN_SAMPLE  = 20      # minimum contracts for chi-square validity
      CHI2_P05    = 15.507  # critical value at p=0.05, df=8  → medium severity
      CHI2_P01    = 20.090  # critical value at p=0.01, df=8  → high severity
      SCORE_MED   = 35
      SCORE_HIGH  = 55
      BATCH_SIZE  = 200     # entities per SQL batch to keep scoped queries small

      # Benford expected probability for each leading digit 1–9
      BENFORD = (1..9).each_with_object({}) do |d, h|
        h[d] = Math.log10(1.0 + 1.0 / d)
      end.freeze

      def call
        # Clean-slate: delete all existing B5 flags upfront.
        # This eliminates the expensive WHERE NOT IN cleanup that caused
        # 20+ min runtimes when 1.87M stale records were present.
        Flag.where(flag_type: FLAG_TYPE).delete_all

        # Pre-filter to entities with enough contracts for statistical validity.
        # Uses the pre-computed contract_count column — instant index scan.
        eligible_ids = Entity.where("contract_count >= ?", MIN_SAMPLE).pluck(:id)

        flagged_count = 0
        batch_num     = 0

        eligible_ids.each_slice(BATCH_SIZE) do |batch_ids|
          batch_num    += 1
          digit_counts  = fetch_digit_counts_for(batch_ids)
          rep_contracts = fetch_representative_contracts(batch_ids)

          now       = Time.current
          analyses  = []
          flag_rows = []

          batch_ids.each do |entity_id|
            counts = digit_counts[entity_id]
            n      = counts&.values&.sum.to_i
            next if n < MIN_SAMPLE

            chi2      = compute_chi2(counts, n)
            anomalous = chi2 >= CHI2_P05
            severity  = anomalous ? (chi2 >= CHI2_P01 ? "high" : "medium") : nil
            dist_json = (1..9).each_with_object({}) { |d, h| h[d.to_s] = counts[d].to_i }

            analyses << {
              entity_id:                  entity_id,
              sample_size:                n,
              chi_square:                 chi2.round(4),
              flagged:                    anomalous,
              severity:                   severity,
              digit_distribution:         dist_json,
              representative_contract_id: rep_contracts[entity_id],
              computed_at:                now,
              created_at:                 now,
              updated_at:                 now
            }

            next unless anomalous

            contract_id = rep_contracts[entity_id]
            next unless contract_id

            flag_rows << {
              contract_id:  contract_id,
              flag_type:    FLAG_TYPE,
              severity:     severity,
              score:        chi2 >= CHI2_P01 ? SCORE_HIGH : SCORE_MED,
              details: {
                "chi2"        => chi2.round(4).to_s,
                "sample_size" => n.to_s,
                "observed"    => dist_json,
                "rule"        => "B5 Benford's Law deviation: chi-square #{chi2.round(4)} " \
                                 "(df=8, n=#{n}, threshold=#{CHI2_P05})"
              },
              fired_at:    now,
              created_at:  now,
              updated_at:  now
            }
          end

          BenfordAnalysis.upsert_all(
            analyses,
            unique_by: :index_benford_analyses_on_entity_id
          ) if analyses.any?

          Flag.upsert_all(
            flag_rows,
            unique_by: :index_flags_on_contract_id_and_flag_type
          ) if flag_rows.any?

          flagged_count += flag_rows.size
          puts "B5 batch #{batch_num}: #{analyses.size} analysed, #{flag_rows.size} flagged " \
               "(total flagged: #{flagged_count})"
        end

        flagged_count
      end

      private

      # Chi-square goodness-of-fit against Benford's distribution (df = 8).
      def compute_chi2(counts, n)
        (1..9).sum do |d|
          observed = counts[d].to_f
          expected = BENFORD[d] * n
          (observed - expected)**2 / expected
        end
      end

      # Returns { entity_id => { digit(int) => count } } scoped to batch_ids only.
      def fetch_digit_counts_for(batch_ids)
        safe_ids = batch_ids.map(&:to_i).join(",")
        sql = <<~SQL
          SELECT contracting_entity_id,
                 SUBSTR(CAST(CAST(base_price AS INTEGER) AS TEXT), 1, 1) AS leading_digit,
                 COUNT(*) AS cnt
          FROM   contracts
          WHERE  base_price >= 1
            AND  contracting_entity_id IN (#{safe_ids})
          GROUP  BY contracting_entity_id, leading_digit
          HAVING leading_digit BETWEEN '1' AND '9'
        SQL

        counts = Hash.new { |h, k| h[k] = Hash.new(0) }
        ApplicationRecord.connection.select_all(sql).each do |row|
          entity_id = row["contracting_entity_id"]
          digit     = row["leading_digit"].to_i
          cnt       = row["cnt"].to_i
          counts[entity_id][digit] += cnt
        end
        counts
      end

      # Returns { entity_id => contract_id } for the representative contract of
      # each entity in the batch. Uses a window function (single-pass, no
      # correlated subqueries). Prefers awarded contracts (celebration_date NOT
      # NULL) ordered by base_price DESC.
      def fetch_representative_contracts(batch_ids)
        safe_ids = batch_ids.map(&:to_i).join(",")
        sql = <<~SQL
          SELECT entity_id, contract_id FROM (
            SELECT contracting_entity_id AS entity_id,
                   id                   AS contract_id,
                   ROW_NUMBER() OVER (
                     PARTITION BY contracting_entity_id
                     ORDER BY (celebration_date IS NOT NULL) DESC, base_price DESC
                   ) AS rn
            FROM contracts
            WHERE contracting_entity_id IN (#{safe_ids})
              AND base_price >= 1
          ) ranked
          WHERE rn = 1
        SQL

        ApplicationRecord.connection.select_all(sql).each_with_object({}) do |row, h|
          h[row["entity_id"]] = row["contract_id"]
        end
      end
    end
  end
end
