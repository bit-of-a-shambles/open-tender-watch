# frozen_string_literal: true

module Flags
  module Actions
    # A9 — Price anomaly
    #
    # Compares the final awarded price (total_effective_price) against the
    # base/estimated price. Two distinct flag types are raised:
    #
    #   A9_PRICE_ANOMALY  — price INCREASE beyond threshold.
    #     This is the higher-risk direction: budget overruns, scope creep after
    #     award, and post-award inflation are classic procurement fraud vectors.
    #     * medium (score 30): ratio > 1.5×  (final > 150% of estimate)
    #     * high   (score 55): ratio > 2.0×  (final > 200% of estimate)
    #
    #   A9_PRICE_REDUCTION — price REDUCTION beyond threshold.
    #     A significant drop can indicate a sham bid (intentionally high base
    #     price to justify a preferred supplier at any final price) or a below-
    #     cost award that may preclude other suppliers. Risk is real but lower.
    #     * low (score 10): ratio < 0.5×  (final < 50% of estimate)
    class PriceAnomalyAction
      FLAG_INCREASE  = "A9_PRICE_ANOMALY"
      FLAG_REDUCTION = "A9_PRICE_REDUCTION"

      RATIO_MIN = 0.5   # below this → reduction flag
      RATIO_MAX = 1.5   # above this → increase flag
      RATIO_HIGH = 2.0  # above this → high severity increase

      SCORE_LOW  = 10
      SCORE_MED  = 30
      SCORE_HIGH = 55

      def call
        rows = anomaly_scope.pluck(:id, :base_price, :total_effective_price)

        increase_ids  = []
        reduction_ids = []
        flag_rows     = []
        now           = Time.current

        rows.each do |contract_id, base_price, effective_price|
          ratio = (effective_price.to_d / base_price.to_d).round(4)

          if ratio > RATIO_MAX
            severity = ratio >= RATIO_HIGH ? "high" : "medium"
            score    = ratio >= RATIO_HIGH ? SCORE_HIGH : SCORE_MED
            increase_ids << contract_id
            flag_rows << build_flag(contract_id, FLAG_INCREASE, severity, score, base_price, effective_price, ratio, now)
          elsif ratio < RATIO_MIN
            reduction_ids << contract_id
            flag_rows << build_flag(contract_id, FLAG_REDUCTION, "low", SCORE_LOW, base_price, effective_price, ratio, now)
          end
        end

        Flag.upsert_all(flag_rows, unique_by: :index_flags_on_contract_id_and_flag_type) if flag_rows.any?

        cleanup_stale_flags(FLAG_INCREASE,  increase_ids)
        cleanup_stale_flags(FLAG_REDUCTION, reduction_ids)

        increase_ids.size + reduction_ids.size
      end

      private

      def anomaly_scope
        Contract
          .where.not(base_price: [ nil, 0 ])
          .where.not(total_effective_price: nil)
          .where(
            "CAST(total_effective_price AS FLOAT) / CAST(base_price AS FLOAT) < ? OR " \
            "CAST(total_effective_price AS FLOAT) / CAST(base_price AS FLOAT) > ?",
            RATIO_MIN, RATIO_MAX
          )
      end

      def build_flag(contract_id, flag_type, severity, score, base_price, effective_price, ratio, now)
        direction = flag_type == FLAG_INCREASE ? "increase" : "reduction"
        {
          contract_id: contract_id,
          flag_type:   flag_type,
          severity:    severity,
          score:       score,
          details: {
            "base_price"            => base_price.to_s,
            "total_effective_price" => effective_price.to_s,
            "ratio"                 => ratio.to_s,
            "direction"             => direction,
            "rule"                  => "A9 price #{direction}: ratio #{ratio} outside [#{RATIO_MIN}, #{RATIO_MAX}]"
          },
          fired_at:   now,
          created_at: now,
          updated_at: now
        }
      end

      def cleanup_stale_flags(flag_type, active_contract_ids)
        scope = Flag.where(flag_type: flag_type)
        if active_contract_ids.empty?
          scope.delete_all
        else
          scope.where.not(contract_id: active_contract_ids).delete_all
        end
      end
    end
  end
end
