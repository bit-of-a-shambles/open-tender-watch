# frozen_string_literal: true

module Flags
  module Actions
    class PotentialConflictOfInterestAction
      FLAG_TYPE = "C7_POTENTIAL_CONFLICT_OF_INTEREST"
      SCORE = 65
      SEVERITY = "high"

      def call
        rows = flagged_rows
        upsert_flags(rows)
        cleanup_stale_flags(rows.map { |row| row[:contract_id] })
        rows.size
      end

      private

      def flagged_rows
        PersonIdentityMatch.actionable.flat_map do |match|
          rows_for_match(match)
        end.uniq { |row| row[:contract_id] }
      end

      def rows_for_match(match)
        public_role = EntityPersonRole.includes(:entity, :person).find_by(id: match.evidence["public_role_id"])
        company_role = EntityPersonRole.includes(:entity, :person).find_by(id: match.evidence["company_role_id"])
        return [] unless usable_roles?(public_role, company_role)

        contracts_for(public_role.entity_id, company_role.entity_id).filter_map do |contract|
          next unless role_covers_contract?(public_role, contract) && role_covers_contract?(company_role, contract)

          {
            contract_id: contract.id,
            match: match,
            public_role: public_role,
            company_role: company_role,
            supplier_entity: company_role.entity,
            public_entity: public_role.entity
          }
        end
      end

      def usable_roles?(public_role, company_role)
        public_role&.active? &&
          company_role&.active? &&
          public_role.entity&.is_public_body? &&
          company_role.entity&.is_company?
      end

      def contracts_for(public_entity_id, company_entity_id)
        Contract.joins(:contract_winners)
          .where(contracting_entity_id: public_entity_id, contract_winners: { entity_id: company_entity_id })
          .distinct
      end

      def role_covers_contract?(role, contract)
        contract_date = contract.publication_date || contract.celebration_date
        return true unless contract_date

        start_date = role.start_date || Date.new(1900, 1, 1)
        end_date = role.end_date || Date.new(2999, 12, 31)
        start_date <= contract_date && contract_date <= end_date
      end

      def upsert_flags(rows)
        return if rows.empty?

        now = Time.current
        Flag.upsert_all(
          rows.map { |row| build_flag_row(row, now) },
          unique_by: :index_flags_on_contract_id_and_flag_type
        )
      end

      def build_flag_row(row, now)
        match = row[:match]
        {
          contract_id: row[:contract_id],
          flag_type: FLAG_TYPE,
          severity: SEVERITY,
          score: SCORE,
          details: {
            "rule" => "c7_shared_individual_link",
            "match_id" => match.id,
            "match_type" => match.match_type,
            "confidence" => match.confidence,
            "public_role_id" => row[:public_role].id,
            "company_role_id" => row[:company_role].id,
            "public_person_name" => row[:public_role].name,
            "company_person_name" => row[:company_role].name,
            "public_entity_id" => row[:public_entity].id,
            "public_entity_name" => row[:public_entity].name,
            "supplier_entity_id" => row[:supplier_entity].id,
            "supplier_name" => row[:supplier_entity].name,
            "public_source" => row[:public_role].source_name,
            "company_source" => row[:company_role].source_name
          },
          fired_at: now,
          created_at: now,
          updated_at: now
        }
      end

      def cleanup_stale_flags(contract_ids)
        stale_scope = Flag.where(flag_type: FLAG_TYPE)
        if contract_ids.empty?
          stale_scope.delete_all
        else
          stale_scope.where.not(contract_id: contract_ids).delete_all
        end
      end
    end
  end
end
