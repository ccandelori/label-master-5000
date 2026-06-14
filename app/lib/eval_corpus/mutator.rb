# frozen_string_literal: true

module EvalCorpus
  # Synthetic negatives: clones of a real application whose declared data
  # is perturbed in one known way, sharing the source's artwork blobs.
  # Each clone is ground truth ("this serial must flag this field"), and
  # blob sharing keeps verification nearly free - the extraction cache is
  # keyed by artwork fingerprint, so only the rules stage re-runs.
  #
  # Zero-schema bookkeeping: the mutation type lives in the serial
  # ("<source>-MUT-<TYPE>") and the expectation table prints at creation.
  module Mutator
    EXPECTED_FLAGS = {
      "BRAND" => "brand_name",
      "NET" => "net_contents",
      "ABV" => "alcohol_content",
      "FANCIFUL" => "fanciful_name",
      "ORIGIN" => "country_of_origin"
    }.freeze

    module_function

    def mutate(source, io:)
      batch = Batch.find_or_create_by!(name: "Mutations of #{source.serial_number}") do |record|
        record.source_kind = "mutation"
      end
      batch.update!(source_kind: "mutation") unless batch.mutation?
      created = mutations_for(source).filter_map do |type, changes|
        serial = "#{source.serial_number}-MUT-#{type}"
        if LabelApplication.exists?(serial_number: serial)
          io.puts "#{serial}: already exists, skipping"
          next
        end

        clone = batch.label_applications.new(
          source.attributes
                .except("id", "batch_id", "row_number", "created_at", "updated_at")
                .merge("serial_number" => serial, "channel" => "submitted", "source_kind" => "mutation")
                .merge(changes)
        )
        clone.artwork.attach(source.artwork.blob)
        clone.back_artwork.attach(source.back_artwork.blob) if source.back_artwork.attached?
        clone.save!
        io.puts "#{serial}: expected flag on #{EXPECTED_FLAGS.fetch(type)}"
        clone
      end

      batch.update!(total_rows: batch.label_applications.count, status: "completed")
      created
    end

    # Only mutations the source can express: ABV needs a declared content,
    # ORIGIN needs an import.
    def mutations_for(source)
      mutations = {
        "BRAND" => { "brand_name" => "#{source.brand_name} RESERVE" },
        "NET" => { "net_contents" => mutated_net_contents(source.net_contents) },
        "FANCIFUL" => { "fanciful_name" => "NONEXISTENT FANCY" }
      }
      if source.alcohol_content.present?
        mutations["ABV"] = { "alcohol_content" => source.alcohol_content + 5.0 }
      end
      if source.imported? && source.country_of_origin.present?
        mutations["ORIGIN"] = {
          "country_of_origin" => source.country_of_origin.casecmp("Chile").zero? ? "Portugal" : "Chile"
        }
      end
      mutations
    end

    # A different legal size: parseable declarations swap between common
    # standards of fill; unparseable ones (registry sentinel) become a
    # concrete size, which the label then cannot match.
    def mutated_net_contents(declared)
      volume = Parsing::NetContents.parse(declared)
      return "750 mL" if volume.nil?

      (volume.milliliters - 750.0).abs < 1.0 ? "1 L" : "750 mL"
    end
  end
end
