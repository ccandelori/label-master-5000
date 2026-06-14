# frozen_string_literal: true

module Reviewer
  class DataQualityController < ApplicationController
    def index
      @area = :data_quality
      @source_counts = LabelApplication.group(:source_kind).count.sort.to_h
      @reviewer_visible_count = LabelApplication.reviewer_visible.count
      @quarantined_count = LabelApplication.where.not(quarantined_at: nil).count
      @quarantine_counts = quarantine_counts
      @quarantined_applications = LabelApplication.where.not(quarantined_at: nil)
                                                   .includes(:batch, artwork_attachment: :blob,
                                                                    back_artwork_attachment: :blob)
                                                   .order(quarantined_at: :desc, id: :desc)
                                                   .limit(100)
    end

    private

    def quarantine_counts
      LabelApplication.where.not(quarantined_at: nil)
                      .pluck(:quarantine_reasons)
                      .flatten
                      .tally
                      .sort
                      .to_h
    end
  end
end
