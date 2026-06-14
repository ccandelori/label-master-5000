# frozen_string_literal: true

module Reviewer
  # Validation history for records users can inspect. Eval, mutation, and
  # quarantined records remain accessible through diagnostics but never
  # pollute this list.
  class QueueController < ApplicationController
    def index
      @area = :history
      entries = ReviewerQueue.entries(history_applications)

      @filters = filters
      @query = @filters[:q]
      @sort = ReviewerQueue.sort_key(params[:sort])
      @direction = ReviewerQueue.sort_direction(params[:direction])
      entries = ReviewerQueue.filter(entries, @filters)

      @tabs = ReviewerQueue.partition(entries, sort: @sort, direction: @direction)
      @tab = ReviewerQueue::TABS.include?(params[:tab]) ? params[:tab] : "needs_attention"
      @entries = @tabs.fetch(@tab)
    end

    private

    def filters
      params.permit(:q, :serial, :brand, :beverage_type, :verdict)
        .to_h.symbolize_keys.transform_values { |value| value.to_s.strip }
    end

    def history_applications
      LabelApplication.validation_history_visible.includes(:verifications, artwork_attachment: :blob)
    end
  end
end
