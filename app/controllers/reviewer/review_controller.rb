# frozen_string_literal: true

module Reviewer
  # Review mode: the immersive annotated screen. The shell embeds the first
  # undecided item; the JS controller pulls subsequent items from next_item,
  # which reuses the same payload builder.
  class ReviewController < ApplicationController
    layout "review_mode"

    # ?start=<application id> pins the opening item (the queue's per-row
    # Review action); the feed continues worst-first from there.
    def show
      @area = :reviewer
      @payload = start_payload || next_payload(skip: [])
    end

    # The next undecided submitted application, worst-first then oldest.
    # ?skip=1,2 excludes ids the reviewer deferred this session.
    def next_item
      skip = params[:skip].to_s.split(",").map(&:to_i)
      payload = next_payload(skip: skip)

      if payload
        render json: payload
      else
        render json: { done: true, remaining: 0 }
      end
    end

    private

    def start_payload
      return nil if params[:start].blank?

      entries = reviewable_entries
      entry = entries.find { |e| e.application.id == params[:start].to_i }
      return nil if entry.nil?

      build_payload(entry, remaining: entries.size)
    end

    def reviewable_entries
      scope = LabelApplication.submitted.includes(:verifications, artwork_attachment: :blob)
      ReviewerQueue.sort(ReviewerQueue.entries(scope).select { |e| ReviewerQueue.reviewable?(e) })
    end

    def next_payload(skip:)
      entries = reviewable_entries
      entry = entries.find { |e| skip.exclude?(e.application.id) }
      return nil if entry.nil?

      build_payload(entry, remaining: entries.size)
    end

    def build_payload(entry, remaining:)
      application = entry.application
      verification = entry.verification
      checks = verification.field_checks

      {
        application: {
          id: application.id,
          serial_number: application.serial_number,
          brand_name: application.brand_name,
          beverage_type: application.beverage_type,
          net_contents: application.net_contents,
          alcohol_content: application.alcohol_content,
          show_path: label_application_path(application)
        },
        verification: {
          id: verification.id,
          overall_verdict: verification.overall_verdict,
          overall_verdict_label: helpers.verdict_label(verification.overall_verdict)
        },
        summary: {
          fails: checks.count { |c| c.verdict == "fail" },
          needs_review: checks.count { |c| c.verdict == "needs_review" },
          passes: checks.count { |c| %w[pass pass_with_note].include?(c.verdict) }
        },
        findings: findings_for(checks),
        artwork_url: artwork_url(application),
        boxes: helpers.bbox_data(verification),
        decision_path: label_application_decision_path(application),
        remaining: remaining
      }
    end

    # The flagged checks, worst first - drives the screen-reader mirror,
    # the no-artwork fallback list, and the absence rail for findings
    # with no located box.
    def findings_for(checks)
      checks.select { |c| %w[fail needs_review].include?(c.verdict) }
            .sort_by { |c| -c.severity }
            .map do |check|
        {
          field: check.field,
          label: helpers.field_label(check.field),
          verdict: check.verdict,
          verdict_label: helpers.verdict_label(check.verdict),
          note: check.note,
          citation: check.citation,
          expected: check.expected,
          extracted: check.extracted
        }
      end
    end

    def artwork_url(application)
      artwork = application.artwork
      return nil unless artwork.attached?

      if artwork.image?
        url_for(artwork)
      elsif artwork.previewable?
        url_for(artwork.preview(resize_to_limit: [ 1400, 1800 ]).processed)
      end
    end
  end
end
