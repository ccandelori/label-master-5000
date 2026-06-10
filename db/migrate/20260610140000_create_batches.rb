# frozen_string_literal: true

class CreateBatches < ActiveRecord::Migration[8.0]
  def change
    create_table :batches do |t|
      t.string :name, null: false
      t.string :status, null: false, default: "pending"
      t.integer :total_rows, null: false, default: 0

      t.timestamps
    end
  end
end
