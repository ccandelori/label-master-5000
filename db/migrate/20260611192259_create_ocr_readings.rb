class CreateOcrReadings < ActiveRecord::Migration[8.0]
  def change
    create_table :ocr_readings do |t|
      t.string :blob_checksum, null: false
      t.string :engine_key, null: false
      t.json :pages, null: false
      t.timestamps
    end
    add_index :ocr_readings, [ :blob_checksum, :engine_key ], unique: true
  end
end
