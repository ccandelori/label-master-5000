class AddChannelToLabelApplications < ActiveRecord::Migration[8.0]
  def change
    # pre_review: manufacturer sandbox record, invisible to reviewers.
    # submitted: filed application, visible in the reviewer queue.
    add_column :label_applications, :channel, :string, null: false, default: "pre_review"
    add_index :label_applications, :channel
  end
end
