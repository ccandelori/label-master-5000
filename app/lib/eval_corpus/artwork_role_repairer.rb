# frozen_string_literal: true

module EvalCorpus
  # Repairs already-imported records whose two stored artwork slots clearly
  # contradict their filenames. Ambiguous records are left unchanged; this is
  # only for high-confidence front/back inversions.
  class ArtworkRoleRepairer
    StoredAttachment = Data.define(:slot, :filename)

    def initialize(scope:, io:, dry_run:)
      @scope = scope
      @io = io
      @dry_run = dry_run
    end

    def repair
      repaired = 0
      @scope.find_each do |application|
        next unless application.artwork.attached? && application.back_artwork.attached?
        next unless swapped?(application)

        if @dry_run
          @io.puts "#{application.serial_number}: would swap artwork/back_artwork"
        else
          swap!(application)
          @io.puts "#{application.serial_number}: swapped artwork/back_artwork"
          repaired += 1
        end
      end
      repaired
    end

    private

    def swapped?(application)
      front = StoredAttachment.new(slot: :artwork, filename: application.artwork.filename.to_s)
      back = StoredAttachment.new(slot: :back_artwork, filename: application.back_artwork.filename.to_s)
      resolved_front, resolved_back = ArtworkRoleResolver.pick_front_back([ front, back ])

      resolved_front == back && resolved_back == front
    end

    def swap!(application)
      front_blob = application.artwork.blob
      back_blob = application.back_artwork.blob

      ApplicationRecord.transaction do
        application.artwork.detach
        application.back_artwork.detach
        application.artwork.attach(back_blob)
        application.back_artwork.attach(front_blob)
        application.save!
      end
    end
  end
end
