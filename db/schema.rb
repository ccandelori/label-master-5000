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

ActiveRecord::Schema[8.0].define(version: 2026_06_13_110000) do
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
    t.string "source_kind", default: "batch_upload", null: false
    t.datetime "processing_started_at"
    t.datetime "processing_completed_at"
    t.index ["source_kind"], name: "index_batches_on_source_kind"
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
    t.string "source_kind", default: "manual", null: false
    t.datetime "quarantined_at"
    t.string "quarantine_reasons", default: [], null: false, array: true
    t.index ["batch_id"], name: "index_label_applications_on_batch_id"
    t.index ["channel", "source_kind", "quarantined_at"], name: "index_label_applications_on_review_visibility"
    t.index ["channel"], name: "index_label_applications_on_channel"
    t.index ["quarantined_at"], name: "index_label_applications_on_quarantined_at"
    t.index ["serial_number"], name: "index_label_applications_on_serial_number"
    t.index ["source_kind"], name: "index_label_applications_on_source_kind"
  end

  create_table "ocr_readings", force: :cascade do |t|
    t.string "blob_checksum", null: false
    t.string "engine_key", null: false
    t.json "pages", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["blob_checksum", "engine_key"], name: "index_ocr_readings_on_blob_checksum_and_engine_key", unique: true
  end

  create_table "verification_attempts", force: :cascade do |t|
    t.bigint "label_application_id", null: false
    t.bigint "verification_id"
    t.string "state", default: "queued", null: false
    t.datetime "processing_started_at"
    t.datetime "processing_completed_at"
    t.integer "queue_wait_ms"
    t.jsonb "stage_timings", default: {}, null: false
    t.string "error_class"
    t.text "error_message"
    t.jsonb "error_context", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["label_application_id", "created_at"], name: "idx_on_label_application_id_created_at_82706e65be"
    t.index ["label_application_id"], name: "index_verification_attempts_on_label_application_id"
    t.index ["state"], name: "index_verification_attempts_on_state"
    t.index ["verification_id"], name: "index_verification_attempts_on_verification_id"
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
    t.string "artwork_fingerprint"
    t.index ["artwork_fingerprint"], name: "index_verifications_on_artwork_fingerprint"
    t.index ["label_application_id"], name: "index_verifications_on_label_application_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "label_applications", "batches"
  add_foreign_key "verification_attempts", "label_applications"
  add_foreign_key "verification_attempts", "verifications"
  add_foreign_key "verifications", "label_applications"
end
