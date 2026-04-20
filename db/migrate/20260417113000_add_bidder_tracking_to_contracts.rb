class AddBidderTrackingToContracts < ActiveRecord::Migration[8.0]
  def change
    add_column :contracts, :bidder_count, :integer

    create_table :contract_bidders do |t|
      t.references :contract, null: false, foreign_key: true
      t.references :entity, null: true, foreign_key: true
      t.string :raw_label, null: false
      t.timestamps
    end

    add_index :contract_bidders, [ :contract_id, :raw_label ], unique: true
    add_index :contracts, :bidder_count
  end
end
