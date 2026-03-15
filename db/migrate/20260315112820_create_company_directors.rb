# frozen_string_literal: true

class CreateCompanyDirectors < ActiveRecord::Migration[8.0]
  def change
    create_table :company_directors do |t|
      t.references :entity, null: false, foreign_key: true
      t.string :name, null: false
      t.string :role
      t.string :tax_identifier
      t.string :country_code, null: false, default: "PT"
      t.timestamps
    end

    add_index :company_directors, %i[entity_id tax_identifier],
              unique: true,
              where: "tax_identifier IS NOT NULL",
              name: "index_company_directors_entity_nif"
  end
end
