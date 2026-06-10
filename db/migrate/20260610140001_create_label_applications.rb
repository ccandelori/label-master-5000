# frozen_string_literal: true

class CreateLabelApplications < ActiveRecord::Migration[8.0]
  def change
    create_table :label_applications do |t|
      t.references :batch, null: true, foreign_key: true
      t.integer :row_number

      t.string :serial_number, null: false
      t.string :beverage_type, null: false
      t.boolean :imported, null: false, default: false
      t.string :brand_name, null: false
      t.string :fanciful_name
      t.text :applicant_name_address, null: false
      t.decimal :alcohol_content, precision: 5, scale: 2
      t.string :net_contents, null: false
      t.string :country_of_origin
      t.text :container_embossed_info

      t.string :varietals, array: true, null: false, default: []
      t.string :appellation
      t.integer :vintage_year

      t.string :declared_class_type
      t.decimal :actual_alcohol_content, precision: 5, scale: 2
      t.boolean :contains_fd_c_yellow_5
      t.boolean :contains_cochineal_carmine
      t.boolean :contains_sulfites_10ppm
      t.boolean :contains_saccharin
      t.boolean :contains_aspartame
      t.boolean :contains_added_coloring

      t.timestamps
    end

    add_index :label_applications, :serial_number
  end
end
