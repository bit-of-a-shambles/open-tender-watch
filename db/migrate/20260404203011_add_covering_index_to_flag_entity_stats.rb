class AddCoveringIndexToFlagEntityStats < ActiveRecord::Migration[8.0]
  def change
    add_index :flag_entity_stats,
              %i[flag_type entity_id severity total_exposure contract_count],
              name: "index_flag_entity_stats_covering"
  end
end
