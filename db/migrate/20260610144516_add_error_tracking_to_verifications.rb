class AddErrorTrackingToVerifications < ActiveRecord::Migration[8.0]
  def change
    add_column :verifications, :error_message, :text
  end
end
