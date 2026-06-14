# frozen_string_literal: true

module Extraction
  # Builds the verifier's raw extraction payload from local OCR pages.
  # The output intentionally matches Schema::RESPONSE_SCHEMA so the rules,
  # evidence overlays, exports, and persisted history do not need a second
  # contract for the fast production path.
  module OcrFirstPayload
    ALCOHOL_WINDOW_WORDS = 12
    DISCLOSURE_WINDOW_WORDS = 8
    COMMODITY_WINDOW_WORDS = 12
    NET_CONTENTS_WINDOW_WORDS = 8
    WARNING_TRAILING_WORDS = 70
    CONFIDENCE_WITH_TEXT = 0.75
    CONFIDENCE_WITHOUT_TEXT = 0.0
    MODEL_ID = "ocr-first-v1"
    NET_CONTENTS_CONTEXT_BLOCKLIST = /\b(serving|container|calories|carbohydrates?|protein|sugar|fat|nutrition)\b/i

    module_function

    def build(application:, pages:, threshold:)
      payload = FieldReconciler.reconcile(
        payload: empty_payload(pages),
        pages: pages,
        application: application,
        threshold: threshold
      )
      payload = put_field(payload, "net_contents", net_contents_slot(pages))
      payload = put_field(payload, "alcohol_statement", alcohol_statement_slot(pages))
      payload = put_field(payload, "government_warning", government_warning_slot(pages))
      payload = put_field(payload, "commodity_statement", commodity_statement_slot(pages))
      payload = payload.merge(
        "varietals" => varietal_slots(application: application, pages: pages, threshold: threshold),
        "disclosures" => disclosure_slots(application: application, pages: pages),
        "warning_attributes" => warning_attributes(payload.dig("fields", "government_warning"))
      )
      payload.merge(
        "legible" => pages.any? { |page| page.words.any? },
        "confidence" => pages.any? { |page| page.words.any? } ? CONFIDENCE_WITH_TEXT : CONFIDENCE_WITHOUT_TEXT
      )
    end

    def empty_payload(pages)
      first = pages.first
      {
        "legible" => false,
        "confidence" => CONFIDENCE_WITHOUT_TEXT,
        "image_width" => first&.width.to_i,
        "image_height" => first&.height.to_i,
        "pages" => pages.map { |page| { "page" => page.number, "width" => page.width, "height" => page.height } },
        "fields" => Schema::FIELD_KEYS.index_with { nil },
        "varietals" => [],
        "disclosures" => [],
        "warning_attributes" => {
          "prefix_all_caps" => nil,
          "prefix_bold" => nil,
          "continuous_paragraph" => nil
        }
      }
    end

    def put_field(payload, field, slot)
      return payload if slot.nil?
      return payload if payload.dig("fields", field, "text").to_s.strip.present?

      payload.merge("fields" => payload["fields"].merge(field => slot))
    end

    def alcohol_statement_slot(pages)
      first_matching_window(pages: pages, max_words: ALCOHOL_WINDOW_WORDS) do |text|
        Parsing::AlcoholStatement.statement?(text)
      end
    end

    def net_contents_slot(pages)
      first_matching_window(pages: pages, max_words: NET_CONTENTS_WINDOW_WORDS) do |text|
        net_contents_statement?(text)
      end
    end

    def government_warning_slot(pages)
      pages.each do |page|
        page.words.each_with_index do |word, index|
          text = word.text.to_s.strip
          next unless warning_start?(text)

          return FieldReconciler.located_slot(text, [ word ], page) if text.upcase.start_with?(Parsing::WarningComparator::PREFIX)

          words = page.words[index, WARNING_TRAILING_WORDS]
          return FieldReconciler.located_slot(words.map(&:text).join(" "), words, page)
        end
      end

      nil
    end

    def commodity_statement_slot(pages)
      first_matching_window(pages: pages, max_words: COMMODITY_WINDOW_WORDS) do |text|
        normalized = Parsing::TextNormalizer.normalize(text)
        normalized.include?("neutral spirits") || normalized.include?("distilled from")
      end
    end

    def varietal_slots(application:, pages:, threshold:)
      Array(application.varietals).filter_map do |varietal|
        tokens = BboxGrounder.tokenize(varietal)
        next if tokens.empty?

        FieldReconciler.locate(tokens, pages, threshold)
      end.uniq { |slot| Parsing::TextNormalizer.normalize(slot["text"]) }
    end

    def disclosure_slots(application:, pages:)
      rules = Rules::Data.for(application.beverage_type)
      Array(rules["disclosures"]).filter_map do |disclosure|
        disclosure_slot(disclosure: disclosure, pages: pages)
      end.uniq { |slot| Parsing::TextNormalizer.normalize(slot["text"]) }
    end

    def disclosure_slot(disclosure:, pages:)
      keywords = Rules::Checks::Disclosures.keyword_set(disclosure)
      first_matching_window(pages: pages, max_words: DISCLOSURE_WINDOW_WORDS) do |text|
        normalized = Parsing::TextNormalizer.normalize(text)
        keywords.any? { |keyword| normalized.include?(keyword) }
      end
    end

    def warning_attributes(warning_slot)
      text = warning_slot&.fetch("text", nil).to_s
      {
        "prefix_all_caps" => text.strip.start_with?(Parsing::WarningComparator::PREFIX),
        "prefix_bold" => nil,
        "continuous_paragraph" => nil
      }
    end

    def first_matching_window(pages:, max_words:)
      pages.each do |page|
        windows(page.words, max_words).each do |words|
          text = words.map(&:text).join(" ")
          return FieldReconciler.located_slot(text, words, page) if yield(text)
        end
      end

      nil
    end

    def windows(words, max_words)
      (1..max_words).flat_map do |length|
        words.each_index.filter_map do |index|
          next if index + length > words.length

          words[index, length]
        end
      end
    end

    def net_contents_statement?(text)
      return false if text.match?(NET_CONTENTS_CONTEXT_BLOCKLIST)

      !Parsing::NetContents.parse(text).nil?
    end

    def warning_start?(text)
      normalized = Parsing::TextNormalizer.normalize(text)
      normalized.include?("government warning") || normalized == "government"
    end
  end
end
