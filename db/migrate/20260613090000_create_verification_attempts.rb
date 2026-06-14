# frozen_string_literal: true

class CreateVerificationAttempts < ActiveRecord::Migration[8.0]
  def change
    create_table :verification_attempts do |t|
      t.references :label_application, null: false, foreign_key: true
      t.references :verification, foreign_key: true
      t.string :state, null: false, default: "queued"
      t.datetime :processing_started_at
      t.datetime :processing_completed_at
      t.integer :queue_wait_ms
      t.jsonb :stage_timings, null: false, default: {}
      t.string :error_class
      t.text :error_message
      t.jsonb :error_context, null: false, default: {}

      t.timestamps
    end

    add_index :verification_attempts, [ :label_application_id, :created_at ]
    add_index :verification_attempts, :state
  end
end
