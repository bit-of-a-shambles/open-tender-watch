class CreateBenfordAnalyses < ActiveRecord::Migration[8.0]
  def change
    create_table :benford_analyses do |t|
      t.references :entity,                  null: false, foreign_key: true, index: { unique: true }
      t.references :representative_contract, null: true,  foreign_key: { to_table: :contracts, on_delete: :nullify }, index: true
      t.integer    :sample_size,             null: false
      t.decimal    :chi_square,              precision: 10, scale: 4, null: false
      t.boolean    :flagged,                 null: false, default: false
      t.string     :severity                 # null = not anomalous
      t.json       :digit_distribution,      null: false, default: {}
      t.datetime   :computed_at,             null: false

      t.timestamps
    end

    add_index :benford_analyses, :flagged
  end
end
