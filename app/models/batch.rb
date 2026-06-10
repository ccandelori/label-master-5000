# frozen_string_literal: true

class Batch < ApplicationRecord
  has_many :label_applications, dependent: :destroy

  enum :status, {
    pending: "pending",
    processing: "processing",
    completed: "completed"
  }, validate: true

  validates :name, presence: true
end
