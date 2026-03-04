# frozen_string_literal: true

class AddUniqueIndexToContractWinners < ActiveRecord::Migration[8.0]
  def change
    add_index :contract_winners, [ :contract_id, :entity_id ], unique: true,
              name: "index_contract_winners_on_contract_id_and_entity_id"
  end
end
