# frozen_string_literal: true

class AddWonStatsToEntities < ActiveRecord::Migration[8.0]
  def change
    add_column :entities, :won_contract_count, :integer, default: 0, null: false
    add_column :entities, :won_value, :decimal, precision: 15, scale: 2, default: "0.0", null: false

    # Index used by CompaniesController#index ORDER BY + WHERE is_company
    add_index :entities, [ :is_company, :won_value ],
              name: "index_entities_on_is_company_won_value"
    add_index :entities, [ :is_company, :won_contract_count ],
              name: "index_entities_on_is_company_won_contract_count"
  end
end
