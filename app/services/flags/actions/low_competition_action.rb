# frozen_string_literal: true

module Flags
  module Actions
    class LowCompetitionAction
      FLAG_TYPE = "A6_LOW_COMPETITION"
      SCORE = 20
      SEVERITY = "medium"

      def call
        flagged_ids = low_competition_scope.pluck(:id)
        upsert_flags(flagged_ids)
        cleanup_stale_flags(flagged_ids)
        flagged_ids.size
      end

      private

      def low_competition_scope
        Contract.where(bidder_count: 1..1)
      end

      def upsert_flags(contract_ids)
        return if contract_ids.empty?

        now = Time.current
        rows = contract_ids.map do |contract_id|
          {
            contract_id: contract_id,
            flag_type: FLAG_TYPE,
            severity: SEVERITY,
            score: SCORE,
            details: { "rule" => "a6_single_bidder", "bidder_count" => 1 },
            fired_at: now,
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
