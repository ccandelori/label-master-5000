class AddRejectionNoticeToVerifications < ActiveRecord::Migration[8.0]
  def change
    add_column :verifications, :rejection_notice, :text
  end
end
