# frozen_string_literal: true

# dedup:run — remove cross-source duplicate contracts.
#
# Strategy:
#   Natural key = (contracting_entity_id, object, base_price,
#                  COALESCE(celebration_date, publication_date), country_code)
#
#   When multiple contracts share the same natural key (same real-world contract
#   ingested from several sources), we keep exactly one, preferring:
#     Portal BASE > SNS > TED > QuemFatura > (unknown/other)
#
#   Before deleting "loser" contracts:
#     - Flags are reassigned to the winner. If the winner already has the same
#       flag_type (unique constraint), the loser's copy is dropped.
#     - ContractWinner rows are reassigned to the winner. If the winner already
#       has that entity, the loser's row is dropped.
#
# Usage:
#   bundle exec rails dedup:run              # commit changes
#   DRY_RUN=1 bundle exec rails dedup:run    # preview only — no DB writes

namespace :dedup do
  SOURCE_PRIORITY = {
    "PublicContracts::PT::PortalBaseClient" => 1,
    "PublicContracts::PT::SnsClient"        => 2,
    "PublicContracts::EU::TedClient"        => 3,
    "PublicContracts::PT::QuemFaturaClient" => 4
  }.freeze

  desc "Remove cross-source duplicate contracts (keeps highest-priority source)"
  task run: :environment do
    dry_run = ENV["DRY_RUN"].present?
    puts dry_run ? "==> DRY RUN — no changes will be committed" : "==> Running deduplication..."

    # Build a lookup: contract_id → source priority
    priority_by_contract = Contract
      .joins("LEFT JOIN data_sources ON data_sources.id = contracts.data_source_id")
      .pluck(Arel.sql("contracts.id"), Arel.sql("COALESCE(data_sources.adapter_class, '')"))
      .each_with_object({}) do |(id, adapter_class), h|
        h[id] = SOURCE_PRIORITY.fetch(adapter_class, 99)
      end

    # Find all natural-key duplicate groups (SQLite GROUP_CONCAT)
    # Only consider groups that span MORE THAN ONE data source (cross-source dupes).
    # Within-source duplicates with identical natural keys are legitimately
    # different contracts (e.g. recurring framework agreements with same entity,
    # description, price, and date across different years).
    duplicate_groups = Contract
      .select(Arel.sql(
        "contracting_entity_id, object, base_price, " \
        "COALESCE(celebration_date, publication_date) AS date_key, " \
        "country_code, GROUP_CONCAT(id) AS contract_ids, " \
        "COUNT(DISTINCT COALESCE(data_source_id, 0)) AS source_count, COUNT(*) AS cnt"
      ))
      .where.not(object: nil)
      .where.not(base_price: nil)
      .where("COALESCE(celebration_date, publication_date) IS NOT NULL")
      .group(Arel.sql(
        "contracting_entity_id, object, base_price, " \
        "COALESCE(celebration_date, publication_date), country_code"
      ))
      .having(Arel.sql("COUNT(*) > 1 AND COUNT(DISTINCT COALESCE(data_source_id, 0)) > 1"))

    groups_processed  = 0
    contracts_deleted = 0
    flags_reassigned  = 0
    flags_dropped     = 0
    winners_merged    = 0

    ActiveRecord::Base.transaction do
      duplicate_groups.each do |group|
        ids = group.contract_ids.to_s.split(",").map(&:to_i)

        # Sort by (source priority ASC, id ASC) — lowest priority number wins
        ranked     = ids.sort_by { |id| [priority_by_contract.fetch(id, 99), id] }
        winner_id  = ranked.first
        loser_ids  = ranked.drop(1)

        # --- Reassign flags --------------------------------------------------
        existing_flag_types = Flag.where(contract_id: winner_id)
                                  .pluck(:flag_type)
                                  .to_set

        Flag.where(contract_id: loser_ids).each do |flag|
          if existing_flag_types.include?(flag.flag_type)
            flags_dropped += 1
            flag.delete unless dry_run
          else
            existing_flag_types.add(flag.flag_type)
            flags_reassigned += 1
            flag.update_columns(contract_id: winner_id) unless dry_run
          end
        end

        # --- Reassign contract_winners ---------------------------------------
        existing_entity_ids = ContractWinner.where(contract_id: winner_id)
                                             .pluck(:entity_id)
                                             .to_set

        ContractWinner.where(contract_id: loser_ids).each do |cw|
          if existing_entity_ids.include?(cw.entity_id)
            cw.delete unless dry_run
          else
            existing_entity_ids.add(cw.entity_id)
            winners_merged += 1
            cw.update_columns(contract_id: winner_id) unless dry_run
          end
        end

        # --- Delete loser contracts ------------------------------------------
        contracts_deleted += loser_ids.size
        Contract.where(id: loser_ids).delete_all unless dry_run

        groups_processed += 1
      end

      raise ActiveRecord::Rollback if dry_run
    end

    puts "Duplicate groups : #{groups_processed}"
    puts "Contracts deleted: #{contracts_deleted}"
    puts "Flags reassigned : #{flags_reassigned}"
    puts "Flags dropped    : #{flags_dropped}  (flag_type already on winner)"
    puts "Winners merged   : #{winners_merged}"
    puts dry_run ? "==> DRY RUN complete — DB unchanged." : "==> Done."
  end
end
