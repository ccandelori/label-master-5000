# frozen_string_literal: true

class CreateVerifications < ActiveRecord::Migration[8.0]
  def change
    create_table :verifications do |t|
      t.references :label_application, null: false, foreign_key: true

      t.string :overall_verdict, null: false
      t.jsonb :field_checks, null: false, default: []
      t.jsonb :extraction
      t.boolean :extraction_reused, null: false, default: false
      t.string :model_id
      t.integer :latency_ms

      t.string :decision
      t.text :decision_note
      t.datetime :decided_at

      t.timestamps
    end
  end
end
