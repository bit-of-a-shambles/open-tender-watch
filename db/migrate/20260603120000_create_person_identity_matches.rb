# frozen_string_literal: true

class CreatePersonIdentityMatches < ActiveRecord::Migration[8.0]
  def change
    create_table :person_identity_matches do |t|
      t.references :left_person, null: false, foreign_key: { to_table: :people }
      t.references :right_person, null: false, foreign_key: { to_table: :people }
      t.string :match_type, null: false
      t.string :confidence, null: false
      t.integer :score, null: false
      t.json :evidence, default: {}, null: false
      t.string :review_status, default: "unreviewed", null: false
      t.datetime :reviewed_at
      t.timestamps
    end

    add_index :person_identity_matches,
              [ :left_person_id, :right_person_id, :match_type ],
              unique: true,
              name: "index_person_identity_matches_unique_pair_type"
    add_index :person_identity_matches, [ :confidence, :review_status ]
  end
end
