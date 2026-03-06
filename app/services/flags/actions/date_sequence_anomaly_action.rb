# frozen_string_literal: true

module Flags
  module Actions
    # A2 — Publication after celebration
    #
    # Flags contracts where the publication date is more than
    # MIN_PUBLICATION_DELAY_DAYS days after the signing (celebration) date.
    #
    # Portuguese law requires signing first, then publishing to BASE — a gap of
    # up to ~10 days is normal administrative practice. Only gaps exceeding this
    # threshold indicate retroactive documentation or deliberate late filing.
    class DateSequenceAnomalyAction
      FLAG_TYPE = "A2_PUBLICATION_AFTER_CELEBRATION"
      SCORE = 40
      SEVERITY = "high"

      # Minimum gap in days between signing and publication before a flag is raised.
      # Gaps at or below this value are normal administrative delays.
      MIN_PUBLICATION_DELAY_DAYS = 10

      def call
        flagged_rows = anomaly_scope.pluck(
          :id,
          :publication_date,
          :celebration_date,
          Arel.sql("CAST(julianday(publication_date) - julianday(celebration_date) AS INTEGER)")
        )
        upsert_flags(flagged_rows)
        cleanup_stale_flags(flagged_rows.map(&:first))
        flagged_rows.size
      end

      private

      def anomaly_scope
        Contract.where.not(publication_date: nil, celebration_date: nil)
                .where("celebration_date < publication_date")
                .where("julianday(publication_date) - julianday(celebration_date) > ?",
                       MIN_PUBLICATION_DELAY_DAYS)
      end

      def upsert_flags(flagged_rows)
        return if flagged_rows.empty?

        now = Time.current
        rows = flagged_rows.map do |contract_id, publication_date, celebration_date, gap_days|
          {
            contract_id: contract_id,
            flag_type: FLAG_TYPE,
            severity: SEVERITY,
            score: SCORE,
            details: {
              "publication_date" => publication_date.iso8601,
              "celebration_date" => celebration_date.iso8601,
              "gap_days"         => gap_days,
              "rule"             => "A2/A3 late publication: #{gap_days} days after signing (threshold: #{MIN_PUBLICATION_DELAY_DAYS})"
            },
            fired_at: now,
            created_at: now,
            updated_at: now
          }
        end

        Flag.upsert_all(rows, unique_by: :index_flags_on_contract_id_and_flag_type)
      end

      def cleanup_stale_flags(flagged_contract_ids)
        stale_scope = Flag.where(flag_type: FLAG_TYPE)
        if flagged_contract_ids.empty?
          stale_scope.delete_all
        else
          stale_scope.where.not(contract_id: flagged_contract_ids).delete_all
        end
      end
    end
  end
end
