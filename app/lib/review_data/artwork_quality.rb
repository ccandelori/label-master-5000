# frozen_string_literal: true

module ReviewData
  # Shared data-quality rules for label artwork associations. These checks
  # identify records that remain useful for diagnostics/eval but should not
  # be trusted as production reviewer work without human inspection.
  module ArtworkQuality
    NECK_OR_COLLAR = /\b(neck|collar)\b/i
    MUTATION_SOURCE_KIND = "mutation"

    ISSUE_LABELS = {
      "identical_front_back_artwork" => "Front and back artwork are identical",
      "primary_artwork_filename_indicates_back" => "Primary artwork filename indicates a back label",
      "back_artwork_filename_indicates_front" => "Back artwork filename indicates a front label",
      "primary_artwork_filename_indicates_neck_or_collar" => "Primary artwork filename indicates neck/collar artwork",
      "artwork_checksum_shared_across_applications" => "Artwork bytes are shared across multiple applications"
    }.freeze

    module_function

    def reasons_for(application:, source_kind:, shared_checksums:)
      return [] if source_kind == MUTATION_SOURCE_KIND

      front = attached_blob(application.artwork)
      back = attached_blob(application.back_artwork)
      reasons = []
      reasons << "identical_front_back_artwork" if front && back && front.checksum == back.checksum
      reasons << "primary_artwork_filename_indicates_back" if filename_role(front) == :back
      reasons << "back_artwork_filename_indicates_front" if filename_role(back) == :front
      reasons << "primary_artwork_filename_indicates_neck_or_collar" if filename_matches?(front, NECK_OR_COLLAR)
      reasons << "artwork_checksum_shared_across_applications" if shared_checksum?(front, back, shared_checksums)
      reasons.uniq
    end

    def import_reasons_for(application:)
      reasons_for(
        application: application,
        source_kind: application.source_kind,
        shared_checksums: shared_checksums_for_import(application)
      )
    end

    def shared_checksums_for_targets(application_targets:)
      eligible_ids = application_targets.reject { |_, source_kind| source_kind == MUTATION_SOURCE_KIND }.keys.map(&:id)
      shared_checksums_for_record_ids(eligible_ids)
    end

    def label_for(reason)
      ISSUE_LABELS.fetch(reason, reason.humanize)
    end

    def labels_for(reasons)
      reasons.map { |reason| label_for(reason) }
    end

    def shared_checksums_for_import(application)
      blobs = [ attached_blob(application.artwork), attached_blob(application.back_artwork) ].compact
      return [] if blobs.empty?

      ActiveStorage::Attachment.joins(:blob)
                               .where(record_type: "LabelApplication")
                               .where(active_storage_blobs: { checksum: blobs.map(&:checksum) })
                               .where.not(record_id: application.id)
                               .joins("INNER JOIN label_applications ON label_applications.id = active_storage_attachments.record_id")
                               .where.not(label_applications: { source_kind: MUTATION_SOURCE_KIND })
                               .pluck("active_storage_blobs.checksum")
                               .uniq
    end

    def shared_checksums_for_record_ids(record_ids)
      return [] if record_ids.empty?

      ActiveStorage::Attachment.where(record_type: "LabelApplication", record_id: record_ids)
                               .includes(:blob)
                               .group_by { |attachment| attachment.blob.checksum }
                               .select { |_, attachments| attachments.map(&:record_id).uniq.many? }
                               .keys
    end

    def attached_blob(attachment)
      attachment.attached? ? attachment.blob : nil
    end

    def filename_role(blob)
      return nil if blob.nil?

      EvalCorpus::ArtworkRoleResolver.filename_role({ filename: blob.filename.to_s })
    end

    def filename_matches?(blob, pattern)
      blob.present? && blob.filename.to_s.match?(pattern)
    end

    def shared_checksum?(front, back, shared_checksums)
      [ front, back ].compact.any? { |blob| shared_checksums.include?(blob.checksum) }
    end
  end
end
