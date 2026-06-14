# frozen_string_literal: true

class AddProcessingTimestampsToBatches < ActiveRecord::Migration[8.0]
  def change
    add_column :batches, :processing_started_at, :datetime
    add_column :batches, :processing_completed_at, :datetime
  end
end
