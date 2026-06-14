# frozen_string_literal: true

module EvalCorpus
  # Builds an evaluation corpus from the public registry: approved labels
  # whose declared data is real, so verification against them measures the
  # false-flag rate. Idempotent by serial (the TTB ID); never enqueues
  # verification - importing must not spend vision-API money.
  class Importer
    HARD_CAP = 50

    # Raised when a record would persist without its label artwork; the
    # surrounding transaction rolls the record back. A record without its
    # label is unusable for evaluation, whatever path produced it.
    class MissingArtwork < StandardError; end

    EVAL_BATCH_PREFIX = "TTB registry eval"

    # TTB IDs are date-structured (YYJJJTTTNNNNNN); walking sequence
    # numbers across a few julian days of a known-public year discovers
    # approved records without scraping the search form.
    DISCOVERY_YEAR = "23"
    DISCOVERY_DAYS = %w[001 010 020 032 045 060].freeze
    DISCOVERY_TYPE = "001"

    def initialize(client:, io:)
      @client = client
      @io = io
    end

    def import(count:, ids_file:)
      count = [ count, HARD_CAP ].min
      batch = Batch.find_or_create_by!(name: "#{EVAL_BATCH_PREFIX} #{Date.current.iso8601}") do |record|
        record.source_kind = "registry_eval"
      end
      batch.update!(source_kind: "registry_eval") unless batch.registry_eval?
      imported = 0
      repaired = 0

      candidate_ids(ids_file).each do |ttb_id|
        break if imported + repaired >= count

        case import_one(ttb_id, batch)
        when :imported then imported += 1
        when :repaired then repaired += 1
        end
      end

      batch.update!(total_rows: batch.label_applications.count, status: "completed")
      @io.puts "imported #{imported} record(s), repaired #{repaired} into batch ##{batch.id} (#{batch.name})"
      @io.puts "run verification with: bin/rails runner 'Batch.find(#{batch.id}).label_applications.find_each { |a| VerifyLabelJob.perform_now(a.id) }'"
      imported + repaired
    end

    private

    def candidate_ids(ids_file)
      if ids_file.present?
        File.readlines(ids_file).map(&:strip).reject(&:empty?)
      else
        Enumerator.new do |yielder|
          DISCOVERY_DAYS.each do |day|
            (1..(HARD_CAP * 2)).each do |sequence|
              yielder << "#{DISCOVERY_YEAR}#{day}#{DISCOVERY_TYPE}#{format('%06d', sequence)}"
            end
          end
        end
      end
    end

    def import_one(ttb_id, batch)
      existing = LabelApplication.find_by(serial_number: ttb_id)
      return repair_or_skip(existing, ttb_id) if existing

      parsed = RegistryRecord.parse_form(@client.form_html(ttb_id))
      if parsed.nil?
        @io.puts "#{ttb_id}: no parseable COLA (unknown id or unmapped product type), skipping"
        return nil
      end

      front, back = pick_artwork(parsed.image_attachments)
      if front.nil?
        @io.puts "#{ttb_id}: no label image on the form view, skipping"
        return nil
      end

      detail = parsed.imported ? RegistryRecord.parse_detail(@client.detail_html(ttb_id)) : {}

      # Built standalone, NOT via batch.label_applications.new: the
      # association proxy keeps unsaved members in its target, and the
      # closing batch.update! autosaves them - which is exactly how
      # failed fetches once left artwork-less records behind.
      application = LabelApplication.new(
        batch: batch,
        serial_number: ttb_id,
        channel: "submitted",
        source_kind: "registry_eval",
        brand_name: parsed.brand_name,
        fanciful_name: parsed.fanciful_name,
        beverage_type: parsed.beverage_type,
        imported: parsed.imported,
        country_of_origin: detail[:origin],
        applicant_name_address: parsed.applicant_name_address,
        appellation: parsed.appellation,
        varietals: parsed.varietals,
        declared_class_type: parsed.declared_class_type,
        vintage_year: parsed.beverage_type == "wine" ? detail[:vintage] : nil,
        net_contents: RegistryRecord::NET_CONTENTS_SENTINEL
      )
      attach(application, :artwork, ttb_id, front)
      attach(application, :back_artwork, ttb_id, back) if back

      save_with_artwork!(application)
      quarantine_artwork_if_needed(application)
      @io.puts "#{ttb_id}: imported #{parsed.brand_name.inspect} (#{parsed.beverage_type}#{back ? ", front+back" : ""})"
      :imported
    rescue RegistryClient::FetchError => e
      @io.puts "#{ttb_id}: fetch failed (#{e.message}), skipping"
      nil
    rescue ActiveRecord::RecordInvalid => e
      @io.puts "#{ttb_id}: invalid record (#{e.message}), skipping"
      nil
    rescue MissingArtwork => e
      @io.puts "#{ttb_id}: #{e.message}, skipping"
      nil
    end

    # An eval-batch record without artwork is the remnant of an import
    # that failed mid-fetch; re-fetching completes it in place, keeping
    # its metadata and batch. Anything else with this serial is done.
    def repair_or_skip(existing, ttb_id)
      if existing.artwork.attached? || !existing.batch&.name.to_s.start_with?(EVAL_BATCH_PREFIX)
        @io.puts "#{ttb_id}: already imported, skipping"
        return nil
      end

      parsed = RegistryRecord.parse_form(@client.form_html(ttb_id))
      if parsed.nil?
        @io.puts "#{ttb_id}: no parseable COLA for repair, skipping"
        return nil
      end

      front, back = pick_artwork(parsed.image_attachments)
      if front.nil?
        @io.puts "#{ttb_id}: no label image on the form view, skipping"
        return nil
      end

      attach(existing, :artwork, ttb_id, front)
      attach(existing, :back_artwork, ttb_id, back) if back && !existing.back_artwork.attached?
      existing.source_kind = "registry_eval"
      batch = existing.batch
      batch.update!(source_kind: "registry_eval") unless batch.registry_eval?

      save_with_artwork!(existing)
      quarantine_artwork_if_needed(existing)
      @io.puts "#{ttb_id}: repaired #{parsed.brand_name.inspect} (artwork attached)"
      :repaired
    rescue RegistryClient::FetchError => e
      @io.puts "#{ttb_id}: fetch failed (#{e.message}), skipping"
      nil
    rescue ActiveRecord::RecordInvalid => e
      @io.puts "#{ttb_id}: invalid record (#{e.message}), skipping"
      nil
    rescue MissingArtwork => e
      @io.puts "#{ttb_id}: #{e.message}, skipping"
      nil
    end

    # Importing is all-or-nothing per record: the save and its attachments
    # commit together, and a record that would land without its label
    # artwork rolls back instead of persisting.
    def save_with_artwork!(application)
      ApplicationRecord.transaction do
        application.save!
        raise MissingArtwork, "no artwork attached after save" unless application.artwork.attached?
      end
    end

    # The brand/front image becomes artwork; a back-typed image becomes
    # back_artwork when it is a raster image (never PDFs). Registry Image
    # Type text is reconciled with filename cues because real forms can
    # contradict themselves.
    def pick_artwork(attachments)
      front, back = ArtworkRoleResolver.pick_front_back(attachments)
      Array(attachments).each do |attachment|
        next unless ArtworkRoleResolver.role_conflict?(attachment)

        @io.puts "attachment role conflict: #{attachment.path}"
      end
      [ front, back ]
    end

    def attach(application, name, ttb_id, attachment)
      filename = attachment.path[/filename=([^&]+)/, 1]
      bytes = @client.attachment(ttb_id, attachment.path)
      application.public_send(name).attach(
        io: StringIO.new(bytes), filename: filename,
        content_type: content_type_for(filename)
      )
    end

    def quarantine_artwork_if_needed(application)
      reasons = ReviewData::ArtworkQuality.import_reasons_for(application: application)
      return if reasons.empty?

      application.quarantine!(reasons: reasons)
      labels = ReviewData::ArtworkQuality.labels_for(reasons).join("; ")
      @io.puts "#{application.serial_number}: quarantined imported artwork (#{labels})"
    end

    def content_type_for(filename)
      case File.extname(filename).downcase
      when ".png" then "image/png"
      when ".webp" then "image/webp"
      else "image/jpeg"
      end
    end
  end
end
