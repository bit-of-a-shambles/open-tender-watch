class AddCompositeIndexOnContractsSortOrder < ActiveRecord::Migration[8.0]
  # The contracts index always orders by celebration_date DESC, id DESC.
  # SQLite can satisfy both the sort and the keyset-style pagination cursor
  # with a single composite index, avoiding a filesort on 2M+ rows.
  def change
    add_index :contracts, [ :celebration_date, :id ],
              order: { celebration_date: :desc, id: :desc },
              name: "index_contracts_on_celebration_date_and_id",
              if_not_exists: true
  end
end
