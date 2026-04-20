class CreateAccessTokenUsages < ActiveRecord::Migration[8.0]
  def change
    create_table :access_token_usages do |t|
      t.references :access_token, null: false, foreign_key: true
      t.string :path
      t.string :ip_address

      t.timestamps
    end
  end
end
