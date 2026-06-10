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

ActiveRecord::Schema[8.0].define(version: 2026_06_10_190844) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "batches", force: :cascade do |t|
    t.string "name", null: false
    t.string "status", default: "pending", null: false
    t.integer "total_rows", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "label_applications", force: :cascade do |t|
    t.bigint "batch_id"
    t.integer "row_number"
    t.string "serial_number", null: false
    t.string "beverage_type", null: false
    t.boolean "imported", default: false, null: false
    t.string "brand_name", null: false
    t.string "fanciful_name"
    t.text "applicant_name_address", null: false
    t.decimal "alcohol_content", precision: 5, scale: 2
    t.string "net_contents", null: false
    t.string "country_of_origin"
    t.text "container_embossed_info"
    t.string "varietals", default: [], null: false, array: true
    t.string "appellation"
    t.integer "vintage_year"
    t.string "declared_class_type"
    t.decimal "actual_alcohol_content", precision: 5, scale: 2
    t.boolean "contains_fd_c_yellow_5"
    t.boolean "contains_cochineal_carmine"
    t.boolean "contains_sulfites_10ppm"
    t.boolean "contains_saccharin"
    t.boolean "contains_aspartame"
    t.boolean "contains_added_coloring"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "channel", default: "pre_review", null: false
    t.index ["batch_id"], name: "index_label_applications_on_batch_id"
    t.index ["channel"], name: "index_label_applications_on_channel"
    t.index ["serial_number"], name: "index_label_applications_on_serial_number"
  end

  create_table "verifications", force: :cascade do |t|
    t.bigint "label_application_id", null: false
    t.string "overall_verdict", null: false
    t.jsonb "field_checks", default: [], null: false
    t.jsonb "extraction"
    t.boolean "extraction_reused", default: false, null: false
    t.string "model_id"
    t.integer "latency_ms"
    t.string "decision"
    t.text "decision_note"
    t.datetime "decided_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "error_message"
    t.text "rejection_notice"
    t.index ["label_application_id"], name: "index_verifications_on_label_application_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "label_applications", "batches"
  add_foreign_key "verifications", "label_applications"
end
