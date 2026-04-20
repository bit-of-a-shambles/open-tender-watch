class CreateAccessTokens < ActiveRecord::Migration[8.0]
  def change
    create_table :access_tokens do |t|
      t.string :token, null: false
      t.string :name, null: false
      t.string :organisation
      t.string :access_level, null: false, default: "journalist"
      t.datetime :expires_at
      t.datetime :last_used_at
      t.integer :usage_count, null: false, default: 0

      t.timestamps
    end
    add_index :access_tokens, :token, unique: true
  end
end
