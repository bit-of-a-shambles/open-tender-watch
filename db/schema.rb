# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_03_06_120000) do
  create_table "benford_analyses", force: :cascade do |t|
    t.integer "entity_id", null: false
    t.integer "representative_contract_id"
    t.integer "sample_size", null: false
    t.decimal "chi_square", precision: 10, scale: 4, null: false
    t.boolean "flagged", default: false, null: false
    t.string "severity"
    t.json "digit_distribution", default: {}, null: false
    t.datetime "computed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id"], name: "index_benford_analyses_on_entity_id", unique: true
    t.index ["flagged"], name: "index_benford_analyses_on_flagged"
    t.index ["representative_contract_id"], name: "index_benford_analyses_on_representative_contract_id"
  end

  create_table "contract_winners", force: :cascade do |t|
    t.integer "contract_id", null: false
    t.integer "entity_id", null: false
    t.decimal "price_share", precision: 15, scale: 2
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["contract_id", "entity_id"], name: "index_contract_winners_on_contract_id_and_entity_id", unique: true
    t.index ["contract_id"], name: "index_contract_winners_on_contract_id"
    t.index ["entity_id"], name: "index_contract_winners_on_entity_id"
  end

  create_table "contracts", force: :cascade do |t|
    t.string "external_id"
    t.integer "contracting_entity_id"
    t.text "object"
    t.string "contract_type"
    t.string "procedure_type"
    t.date "publication_date"
    t.date "celebration_date"
    t.decimal "base_price", precision: 15, scale: 2
    t.decimal "total_effective_price", precision: 15, scale: 2
    t.string "cpv_code"
    t.string "location"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "country_code", default: "PT", null: false
    t.integer "data_source_id"
    t.index ["base_price", "id"], name: "index_contracts_on_base_price_and_id"
    t.index ["base_price"], name: "index_contracts_on_base_price"
    t.index ["celebration_date", "id"], name: "index_contracts_on_celebration_date_and_id", order: :desc
    t.index ["celebration_date"], name: "index_contracts_on_celebration_date"
    t.index ["contracting_entity_id"], name: "index_contracts_on_contracting_entity_id"
    t.index ["country_code"], name: "index_contracts_on_country_code"
    t.index ["cpv_code"], name: "index_contracts_on_cpv_code"
    t.index ["data_source_id"], name: "index_contracts_on_data_source_id"
    t.index ["external_id", "country_code"], name: "index_contracts_on_external_id_and_country_code", unique: true
    t.index ["procedure_type"], name: "index_contracts_on_procedure_type"
    t.index ["publication_date"], name: "index_contracts_on_publication_date"
    t.index ["total_effective_price"], name: "index_contracts_on_total_effective_price"
  end

  create_table "data_sources", force: :cascade do |t|
    t.string "country_code", null: false
    t.string "name", null: false
    t.string "source_type", null: false
    t.string "adapter_class", null: false
    t.text "config"
    t.string "status", default: "inactive", null: false
    t.datetime "last_synced_at"
    t.integer "record_count", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["country_code"], name: "index_data_sources_on_country_code"
    t.index ["status"], name: "index_data_sources_on_status"
  end

  create_table "entities", force: :cascade do |t|
    t.string "name"
    t.string "tax_identifier"
    t.boolean "is_public_body"
    t.boolean "is_company"
    t.string "address"
    t.string "postal_code"
    t.string "locality"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "country_code", default: "PT", null: false
    t.integer "contract_count", default: 0, null: false
    t.decimal "total_contracted_value", precision: 15, scale: 2, default: "0.0", null: false
    t.index ["contract_count"], name: "index_entities_on_contract_count"
    t.index ["is_company"], name: "index_entities_on_is_company"
    t.index ["is_public_body"], name: "index_entities_on_is_public_body"
    t.index ["tax_identifier", "country_code"], name: "index_entities_on_tax_identifier_and_country_code", unique: true
  end

  create_table "flag_entity_stats", force: :cascade do |t|
    t.integer "entity_id", null: false
    t.string "flag_type", null: false
    t.string "severity", null: false
    t.decimal "total_exposure", precision: 15, scale: 2, default: "0.0", null: false
    t.integer "contract_count", default: 0, null: false
    t.datetime "computed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "flag_type", "severity"], name: "index_flag_entity_stats_unique", unique: true
    t.index ["entity_id"], name: "index_flag_entity_stats_on_entity_id"
    t.index ["severity", "contract_count"], name: "index_flag_entity_stats_sev_count"
    t.index ["severity", "total_exposure"], name: "index_flag_entity_stats_sev_exposure"
  end

  create_table "flag_summary_stats", force: :cascade do |t|
    t.string "severity"
    t.decimal "total_exposure", precision: 15, scale: 2, default: "0.0", null: false
    t.integer "flagged_contract_count", default: 0, null: false
    t.integer "flagged_companies_count", default: 0, null: false
    t.integer "flagged_public_entities_count", default: 0, null: false
    t.datetime "computed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["severity"], name: "index_flag_summary_stats_on_severity", unique: true
  end

  create_table "flags", force: :cascade do |t|
    t.integer "contract_id", null: false
    t.string "flag_type", null: false
    t.string "severity", null: false
    t.integer "score", null: false
    t.json "details", default: {}
    t.datetime "fired_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["contract_id", "flag_type"], name: "index_flags_on_contract_id_and_flag_type", unique: true
    t.index ["contract_id"], name: "index_flags_on_contract_id"
    t.index ["flag_type"], name: "index_flags_on_flag_type"
    t.index ["severity", "flag_type", "contract_id"], name: "index_flags_on_severity_flag_type_contract_id"
    t.index ["severity"], name: "index_flags_on_severity"
  end

  add_foreign_key "benford_analyses", "contracts", column: "representative_contract_id", on_delete: :nullify
  add_foreign_key "benford_analyses", "entities"
  add_foreign_key "contract_winners", "contracts"
  add_foreign_key "contract_winners", "entities"
  add_foreign_key "contracts", "data_sources"
  add_foreign_key "contracts", "entities", column: "contracting_entity_id"
  add_foreign_key "flag_entity_stats", "entities"
  add_foreign_key "flags", "contracts"
end
