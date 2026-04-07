# frozen_string_literal: true

module Flags
  module Actions
    class RepeatDirectAwardAction
      FLAG_TYPE    = "A1_REPEAT_DIRECT_AWARD"
      SCORE        = 50
      SEVERITY     = "high"

      # CCP Art. 113 §2 thresholds for ajuste direto:
      MIN_AWARDS          = 2          # at least 2 awards to constitute "repeat"
      WORKS_CPV_PREFIX    = "45"       # CPV section 45 = empreitadas de obras públicas
      WORKS_THRESHOLD     = 30_000.0   # Art. 19(d): ajuste direto for works < €30k
      SERVICES_THRESHOLD  = 20_000.0   # Art. 20(1)(d): ajuste direto for goods/services < €20k

      # Economic year window: current year + 2 preceding years (Art. 113 §2)
      def self.window_start = Date.new(Date.current.year - 2, 1, 1)

      DIRECT_AWARD_PATTERN = "%ajuste%direto%"

      def call
        flagged_rows = qualifying_rows
        upsert_flags(flagged_rows)
        cleanup_stale_flags(flagged_rows)
        flagged_rows.size
      end

      private

      def qualifying_rows
        window = self.class.window_start

        groups = direct_awards
          .joins(:contract_winners)
          .where.not(publication_date: nil)
          .where("contracts.publication_date >= ?", window)
          .group("contracts.contracting_entity_id, contract_winners.entity_id")
          .having(Arel.sql(<<~SQL.squish))
            COUNT(*) >= #{MIN_AWARDS}
            AND (
              SUM(CASE WHEN contracts.cpv_code LIKE '#{WORKS_CPV_PREFIX}%'
                   THEN COALESCE(contracts.base_price, 0) ELSE 0 END) >= #{WORKS_THRESHOLD}
              OR
              SUM(CASE WHEN contracts.cpv_code NOT LIKE '#{WORKS_CPV_PREFIX}%'
                        OR contracts.cpv_code IS NULL
                   THEN COALESCE(contracts.base_price, 0) ELSE 0 END) >= #{SERVICES_THRESHOLD}
            )
          SQL
          .pluck(
            Arel.sql("contracts.contracting_entity_id"),
            Arel.sql("contract_winners.entity_id"),
            Arel.sql("COUNT(*)"),
            Arel.sql("SUM(COALESCE(contracts.base_price, 0))"),
            Arel.sql("SUM(CASE WHEN contracts.cpv_code LIKE '#{WORKS_CPV_PREFIX}%' THEN COALESCE(contracts.base_price, 0) ELSE 0 END)"),
            Arel.sql("SUM(CASE WHEN contracts.cpv_code NOT LIKE '#{WORKS_CPV_PREFIX}%' OR contracts.cpv_code IS NULL THEN COALESCE(contracts.base_price, 0) ELSE 0 END)")
          )

        return [] if groups.empty?

        groups.flat_map do |auth_id, sup_id, count, total_price, works_price, services_price|
          direct_awards
            .joins(:contract_winners)
            .where.not(publication_date: nil)
            .where("contracts.publication_date >= ?", window)
            .where(contracting_entity_id: auth_id, contract_winners: { entity_id: sup_id })
            .pluck(:id)
            .map { |id| [ id, auth_id, sup_id, count, total_price, works_price, services_price ] }
        end
      end

      def upsert_flags(flagged_rows)
        return if flagged_rows.empty?

        supplier_ids   = flagged_rows.map { |_, _, sup_id, *| sup_id }.uniq
        supplier_names = Entity.where(id: supplier_ids).pluck(:id, :name).to_h

        window_from = self.class.window_start.to_s
        window_to   = Date.new(Date.current.year, 12, 31).to_s

        now = Time.current
        rows = flagged_rows.map do |contract_id, auth_id, sup_id, award_count, total_price, works_price, services_price|
          {
            contract_id: contract_id,
            flag_type: FLAG_TYPE,
            severity: SEVERITY,
            score: SCORE,
            details: {
              "supplier_name"  => supplier_names[sup_id],
              "award_count"    => award_count,
              "total_price"    => total_price.to_f,
              "works_price"    => works_price.to_f,
              "services_price" => services_price.to_f,
              "window_from"    => window_from,
              "window_to"      => window_to,
              "rule"           => "a1_threshold_exceeded"
            },
            fired_at: now,
            created_at: now,
            updated_at: now
          }
        end

        Flag.upsert_all(rows, unique_by: :index_flags_on_contract_id_and_flag_type)
      end

      def cleanup_stale_flags(flagged_rows)
        contract_ids = flagged_rows.map(&:first)
        stale_scope  = Flag.where(flag_type: FLAG_TYPE)
        if contract_ids.empty?
          stale_scope.delete_all
        else
          stale_scope.where.not(contract_id: contract_ids).delete_all
        end
      end

      def direct_awards
        Contract.where(Contract.arel_table[:procedure_type].matches(DIRECT_AWARD_PATTERN))
      end
    end
  end
end
