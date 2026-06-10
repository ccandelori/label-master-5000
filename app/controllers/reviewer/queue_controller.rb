# frozen_string_literal: true

module Reviewer
  # The reviewer-facing queue of filed applications. Only submitted records
  # appear here; manufacturer pre-review sandboxes are invisible.
  class QueueController < ApplicationController
    def index
      @area = :reviewer
      @applications = LabelApplication.submitted
                                      .order(created_at: :desc)
                                      .includes(:verifications, artwork_attachment: :blob)
    end
  end
end
