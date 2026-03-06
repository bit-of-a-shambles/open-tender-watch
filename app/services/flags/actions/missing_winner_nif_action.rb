# frozen_string_literal: true

module Flags
  module Actions
    # C1 — Missing supplier NIF / unidentified winner
    #
    # Two cases are covered:
    #   (a) Blank NIF — a ContractWinner exists but the entity has no tax_identifier.
    #       Per OECD guidance, missing VAT numbers are themselves a risk signal.
    #   (b) No winner recorded — the contract carries a positive effective price
    #       (i.e. it was awarded) but has no ContractWinner rows at all.
    #       Investigation of BASE data found ~217K such contracts (10.5% of BASE);
    #       the vast majority are "Ajuste Direto" direct awards where the contracting
    #       authority published the notice without completing the supplier fields.
    #       This is a known BASE data quality pattern and is flagged here as C1.
    class MissingWinnerNifAction
      FLAG_TYPE = "C1_MISSING_WINNER_NIF"
      SCORE     = 25
      SEVERITY  = "medium"

      def call
        blank_nif_ids = blank_nif_scope.pluck(:id)
        no_winner_ids = no_winner_awarded_scope.pluck(:id) - blank_nif_ids
        all_ids       = blank_nif_ids + no_winner_ids

        upsert_flags(blank_nif_ids, no_winner_ids)
        cleanup_stale_flags(all_ids)
        all_ids.size
      end

      private

      # Contracts where at least one winner entity has no tax_identifier.
      def blank_nif_scope
        Contract
          .joins(contract_winners: :entity)
          .where("entities.tax_identifier IS NULL OR entities.tax_identifier = ''")
          .distinct
      end

      # Awarded contracts (positive effective price) with no winner rows at all.
      def no_winner_awarded_scope
        Contract
          .where("total_effective_price > 0")
          .where.not(id: ContractWinner.select(:contract_id))
          .distinct
      end

      def upsert_flags(blank_nif_ids, no_winner_ids)
        return if blank_nif_ids.empty? && no_winner_ids.empty?

        now  = Time.current
        rows = []

        blank_nif_ids.each do |contract_id|
          rows << build_row(contract_id,
                            "C1 missing winner NIF: at least one contracting party has no tax identifier",
                            now)
        end

        no_winner_ids.each do |contract_id|
          rows << build_row(contract_id,
                            "C1 no winner recorded: awarded contract (effective price > 0) has no supplier identified",
                            now)
        end

        Flag.upsert_all(rows, unique_by: :index_flags_on_contract_id_and_flag_type)
      end

      def build_row(contract_id, rule_text, now)
        {
          contract_id: contract_id,
          flag_type:   FLAG_TYPE,
          severity:    SEVERITY,
          score:       SCORE,
          details: {
            "rule" => rule_text
          },
          fired_at:   now,
          created_at: now,
          updated_at: now
        }
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
