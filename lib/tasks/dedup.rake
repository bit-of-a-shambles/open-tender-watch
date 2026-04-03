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
        ranked     = ids.sort_by { |id| [ priority_by_contract.fetch(id, 99), id ] }
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

  # ---------------------------------------------------------------------------
  # dedup:ted_same_tender — collapse within-source TED notice duplicates.
  #
  # TED publishes multiple notices per procurement (contract notice, corrigenda,
  # modifications, award notices) all with distinct publication numbers but
  # representing the same physical tender.  Before the TED client was patched to
  # skip COR/can-modifies notices, they were imported as separate Contract rows.
  # Additionally, multi-lot frameworks often generate one award notice per winner
  # per lot — all sharing the same entity, title, and (optionally) base price.
  #
  # Strategy:
  #   Group by (data_source_id, contracting_entity_id, object, COALESCE(base_price, '-'))
  #   within the TED data source.  This handles both priced and null-price notice
  #   clusters.  For each group with more than one contract, keep the one with the
  #   lowest id (earliest imported ≈ original CN notice).
  #   Reassign flags & winners then delete the rest — identical logic to dedup:run.
  #
  # Usage:
  #   bundle exec rails dedup:ted_same_tender
  #   DRY_RUN=1 bundle exec rails dedup:ted_same_tender
  # ---------------------------------------------------------------------------
  desc "Collapse within-source TED notice duplicates (corrigenda / modifications + multi-lot award notices)"
  task ted_same_tender: :environment do
    dry_run = ENV["DRY_RUN"].present?
    puts dry_run ? "==> DRY RUN — no changes will be committed" : "==> Deduplicating within-source TED notices..."

    ted_source_ids = DataSource
      .where(adapter_class: "PublicContracts::EU::TedClient")
      .pluck(:id)

    if ted_source_ids.empty?
      puts "No TED DataSource records found — nothing to do."
      next
    end

    # Groups where the same entity+title+price appears more than once in TED.
    # COALESCE(base_price, -1) ensures null-price records are grouped together
    # by title; non-null prices are already distinct enough for dedup.
    # Only consider contract rows with an object/title — titleless rows are rare
    # and too ambiguous to merge safely.
    duplicate_groups = Contract
      .select(Arel.sql(
        "data_source_id, contracting_entity_id, COALESCE(CAST(base_price AS TEXT), '') AS price_key, " \
        "object, GROUP_CONCAT(id) AS contract_ids, COUNT(*) AS cnt"
      ))
      .where(data_source_id: ted_source_ids)
      .where.not(object: [ nil, "" ])
      .group(Arel.sql("data_source_id, contracting_entity_id, COALESCE(CAST(base_price AS TEXT), ''), object"))
      .having("COUNT(*) > 1")

    groups_processed  = 0
    contracts_deleted = 0
    flags_reassigned  = 0
    flags_dropped     = 0
    winners_merged    = 0

    ActiveRecord::Base.transaction do
      duplicate_groups.each do |group|
        ids = group.contract_ids.to_s.split(",").map(&:to_i).sort
        winner_id = ids.first
        loser_ids = ids.drop(1)

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
    Entities::UpdateStatsService.new.call unless dry_run
  end
end
