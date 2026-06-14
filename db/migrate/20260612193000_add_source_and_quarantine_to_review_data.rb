# frozen_string_literal: true

class AddSourceAndQuarantineToReviewData < ActiveRecord::Migration[8.0]
  def change
    add_column :batches, :source_kind, :string, null: false, default: "batch_upload"
    add_index :batches, :source_kind

    add_column :label_applications, :source_kind, :string, null: false, default: "manual"
    add_column :label_applications, :quarantined_at, :datetime
    add_column :label_applications, :quarantine_reasons, :string, array: true, null: false, default: []

    add_index :label_applications, :source_kind
    add_index :label_applications, :quarantined_at
    add_index :label_applications, [ :channel, :source_kind, :quarantined_at ],
              name: "index_label_applications_on_review_visibility"
  end
end
