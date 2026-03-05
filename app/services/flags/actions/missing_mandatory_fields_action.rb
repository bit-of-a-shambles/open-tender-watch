# frozen_string_literal: true

module Flags
  module Actions
    # C3 — Missing mandatory fields
    #
    # Contracts that are missing CPV code, procedure type, or base price.
    # Absence of these fields is a risk signal in itself — it may indicate
    # evasion, late entry, or data manipulation.
    class MissingMandatoryFieldsAction
      FLAG_TYPE = "C3_MISSING_MANDATORY_FIELDS"
      SCORE     = 20
      SEVERITY  = "low"

      def call
        flagged_rows = anomaly_scope.pluck(:id, :cpv_code, :procedure_type, :base_price)
        upsert_flags(flagged_rows)
        cleanup_stale_flags(flagged_rows.map(&:first))
        flagged_rows.size
      end

      private

      def anomaly_scope
        Contract.where(
          "cpv_code IS NULL OR procedure_type IS NULL OR base_price IS NULL"
        )
      end

      def upsert_flags(flagged_rows)
        return if flagged_rows.empty?

        now = Time.current
        rows = flagged_rows.map do |contract_id, cpv_code, procedure_type, base_price|
          missing = []
          missing << "cpv_code"      if cpv_code.nil?
          missing << "procedure_type" if procedure_type.nil?
          missing << "base_price"    if base_price.nil?

          {
            contract_id: contract_id,
            flag_type:   FLAG_TYPE,
            severity:    SEVERITY,
            score:       SCORE,
            details: {
              "missing_fields" => missing,
              "rule"           => "C3 missing mandatory fields: #{missing.join(', ')}"
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
