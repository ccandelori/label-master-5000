# frozen_string_literal: true

class Batch < ApplicationRecord
  has_many :label_applications, dependent: :destroy

  enum :status, {
    pending: "pending",
    processing: "processing",
    completed: "completed"
  }, validate: true

  validates :name, presence: true

  def done_count
    label_applications.where(id: Verification.select(:label_application_id)).count
  end

  def progress_percent
    return 0 if total_rows.zero?

    (done_count * 100.0 / total_rows).round
  end

  def verdict_counts
    latest_ids = Verification.group(:label_application_id)
                             .where(label_application: label_applications)
                             .maximum(:id).values
    Verification.where(id: latest_ids).group(:overall_verdict).count
  end
end
