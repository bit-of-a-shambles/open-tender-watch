# frozen_string_literal: true

module Flags
  module Actions
    # C1 — Missing supplier NIF
    #
    # Contracts where at least one winner entity has no tax_identifier.
    # Per OECD guidance, missing VAT numbers are themselves a risk signal and
    # indicate either evasion or incomplete data entry.
    class MissingWinnerNifAction
      FLAG_TYPE = "C1_MISSING_WINNER_NIF"
      SCORE     = 25
      SEVERITY  = "medium"

      def call
        flagged_ids = anomaly_scope.pluck(:id)
        upsert_flags(flagged_ids)
        cleanup_stale_flags(flagged_ids)
        flagged_ids.size
      end

      private

      def anomaly_scope
        Contract
          .joins(contract_winners: :entity)
          .where("entities.tax_identifier IS NULL OR entities.tax_identifier = ''")
          .distinct
      end

      def upsert_flags(flagged_ids)
        return if flagged_ids.empty?

        now = Time.current
        rows = flagged_ids.map do |contract_id|
          {
            contract_id: contract_id,
            flag_type:   FLAG_TYPE,
            severity:    SEVERITY,
            score:       SCORE,
            details: {
              "rule" => "C1 missing winner NIF: at least one contracting party has no tax identifier"
            },
            fired_at:   now,
            created_at: now,
            updated_at: now
          }
        end

        Flag.upsert_all(rows, unique_by: :index_flags_on_contract_id_and_flag_type)
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
