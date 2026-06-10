# frozen_string_literal: true

module Reviewer
  # The reviewer-facing queue of filed applications. Only submitted records
  # appear here; manufacturer pre-review sandboxes are invisible.
  class QueueController < ApplicationController
    def index
      @area = :reviewer
      entries = ReviewerQueue.entries(submitted_applications)

      @query = params[:q].to_s.strip
      entries = ReviewerQueue.search(entries, @query) if @query.present?

      @tabs = ReviewerQueue.partition(entries)
      @tab = ReviewerQueue::TABS.include?(params[:tab]) ? params[:tab] : "needs_attention"
      @entries = @tabs.fetch(@tab)
    end

    private

    def submitted_applications
      LabelApplication.submitted.includes(:verifications, artwork_attachment: :blob)
    end
  end
end
