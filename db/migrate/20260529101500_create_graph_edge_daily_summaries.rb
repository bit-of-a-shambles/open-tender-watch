# frozen_string_literal: true

class CreateGraphEdgeDailySummaries < ActiveRecord::Migration[8.0]
  def change
    create_table :graph_edge_daily_summaries do |t|
      t.integer :source_entity_id, null: false
      t.integer :target_entity_id, null: false
      t.date :publication_date
      t.integer :data_source_id
      t.integer :contract_count, null: false, default: 0
      t.decimal :total_value, precision: 15, scale: 2, null: false, default: 0
      t.integer :flagged_contract_count, null: false, default: 0
      t.decimal :flagged_total_value, precision: 15, scale: 2, null: false, default: 0
      t.integer :risk_total_score, null: false, default: 0
      t.boolean :source_is_public_body, null: false, default: false
      t.boolean :source_is_company, null: false, default: false
      t.boolean :target_is_public_body, null: false, default: false
      t.boolean :target_is_company, null: false, default: false
      t.datetime :computed_at, null: false

      t.timestamps
    end

    add_index :graph_edge_daily_summaries,
              [ :source_entity_id, :target_entity_id, :publication_date, :data_source_id ],
              name: "idx_graph_edge_daily_summary_lookup"
    add_index :graph_edge_daily_summaries,
              [ :source_entity_id, :publication_date ],
              name: "idx_graph_edge_daily_summary_source_date"
    add_index :graph_edge_daily_summaries,
              [ :target_entity_id, :publication_date ],
              name: "idx_graph_edge_daily_summary_target_date"
    add_index :graph_edge_daily_summaries,
              [ :publication_date, :data_source_id ],
              name: "idx_graph_edge_daily_summary_date_source"
    add_index :graph_edge_daily_summaries, :computed_at

    add_foreign_key :graph_edge_daily_summaries, :entities, column: :source_entity_id
    add_foreign_key :graph_edge_daily_summaries, :entities, column: :target_entity_id
    add_foreign_key :graph_edge_daily_summaries, :data_sources
  end
end
