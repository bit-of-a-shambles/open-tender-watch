class AddCoveringIndexToFlags < ActiveRecord::Migration[8.0]
  def change
    # Covering composite index for severity-filtered entity_exposure_rows queries.
    #
    # The entity_exposure_rows query filters on severity and groups by flag_type,
    # then joins to contracts via contract_id.  Without this index SQLite uses
    # the single-column severity index which causes random I/O back into the
    # main table for every matching row — paradoxically slower than a full scan
    # when 10-25 % of rows match.
    #
    # With (severity, flag_type, contract_id) covering the three columns needed
    # from the flags table, SQLite can walk the index leaf pages sequentially
    # and never touch the main table at all, reducing the ~30 s cold query for
    # severity=medium (566 K rows) to under 2 s.
    add_index :flags, %i[severity flag_type contract_id],
              name: "index_flags_on_severity_flag_type_contract_id"
  end
end
