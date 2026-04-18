# frozen_string_literal: true

class CreatePeopleAndEntityPersonRoles < ActiveRecord::Migration[8.0]
  def change
    create_table :people do |t|
      t.string :name, null: false
      t.string :tax_identifier
      t.string :country_code, null: false, default: "PT"
      t.timestamps
    end

    add_index :people, [ :tax_identifier, :country_code ], unique: true, where: "tax_identifier IS NOT NULL"
    add_index :people, [ :name, :country_code ]

    create_table :entity_person_roles do |t|
      t.references :entity, null: false, foreign_key: true
      t.references :person, null: false, foreign_key: true
      t.string :role_type, null: false
      t.string :role_label
      t.string :source_name, null: false
      t.text :source_url
      t.date :source_publication_date
      t.boolean :active, null: false, default: true
      t.datetime :verified_at
      t.timestamps
    end

    add_index :entity_person_roles,
              [ :entity_id, :person_id, :role_type, :source_name, :active ],
              unique: true,
              name: "index_entity_person_roles_unique_active_state"
    add_index :entity_person_roles, [ :entity_id, :active ]
    add_index :entity_person_roles, [ :person_id, :active ]
  end
end