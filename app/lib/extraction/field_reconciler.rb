# frozen_string_literal: true

module Extraction
  # Expectation-driven location: the application's declared values are the
  # search targets, hunted in the OCR word pool, instead of trusting the
  # model's free reading and checking it afterwards. For every declared
  # field whose text is found on the label, the located printed form and
  # its true box replace the model's guess; a miss keeps the model's read
  # (it may faithfully show what IS printed, which the rules then flag).
  #
  # Boundary note: the extraction call itself stays application-blind -
  # this runs after it, in the job, against OCR output that never leaves
  # the host. Pure and total, like BboxGrounder.
  module FieldReconciler
    # Fields whose declared application value should appear on the label
    # verbatim (modulo case, spacing, punctuation, and OCR noise).
    DECLARED_FIELDS = {
      "brand_name" => :brand_name,
      "fanciful_name" => :fanciful_name,
      "appellation" => :appellation,
      "vintage" => :vintage_year,
      "net_contents" => :net_contents
    }.freeze
    SPLIT_DECLARED_MAX_WORDS = 8
    SPLIT_DECLARED_MAX_HEIGHT_RATIO = 0.35
    CLASS_TYPE_WINDOW_WORDS = 6
    CLASS_TYPE_CONTEXT_BLOCKLIST = /\b(government|warning|surgeon|calories|serving|alc|vol|ml|oz|proof)\b/i

    module_function

    # The orchestrator the job calls: declared fields, then the two
    # statement-shaped reconciliations (country of origin and the
    # name/address statement carry their value inside a longer line).
    def reconcile(payload:, pages:, application:, threshold:)
      refined = payload
      DECLARED_FIELDS.each do |field, attribute|
        refined = reconcile_declared(
          payload: refined, pages: pages, field: field,
          expected: application.public_send(attribute).to_s, threshold: threshold
        )
      end
      refined = reconcile_split_fanciful_name(payload: refined, pages: pages, application: application)
      refined = reconcile_class_type_designation(payload: refined, pages: pages, application: application, threshold: threshold)
      refined = reconcile_statement_field(
        payload: refined, pages: pages, field: "country_of_origin_statement",
        expected: application.country_of_origin.to_s, threshold: threshold
      )
      refined = reconcile_name_address(
        payload: refined, pages: pages,
        expected: application.applicant_name_address, threshold: threshold
      )
      reconcile_varietals(payload: refined, pages: pages, application: application, threshold: threshold)
    end

    # Locates one declared value and replaces the field slot on a hit.
    # The model's own reading survives the replacement under "model_text":
    # located text carries the print's true geometry but also its OCR
    # character noise, and the rules accept a declared-value match against
    # either form. Reused extractions re-reconcile an already-located
    # slot, so an existing model_text is carried forward, not re-derived.
    def reconcile_declared(payload:, pages:, field:, expected:, threshold:)
      return payload if Parsing::ApplicationValue.not_stated?(expected)

      target_tokens = BboxGrounder.tokenize(expected)
      return payload if target_tokens.empty?

      located = locate(target_tokens, pages, threshold)
      return payload if located.nil?

      fields = payload["fields"].is_a?(Hash) ? payload["fields"] : {}
      prior = fields[field].is_a?(Hash) ? fields[field] : {}
      model_text = prior["model_text"].to_s.strip
      model_text = prior["text"].to_s.strip if model_text.empty?
      located = located.merge("model_text" => model_text) if !model_text.empty? && model_text != located["text"]

      payload.merge("fields" => fields.merge(field => located))
    end

    def reconcile_split_fanciful_name(payload:, pages:, application:)
      expected = application.fanciful_name.to_s
      target_tokens = BboxGrounder.tokenize(expected)
      return payload if target_tokens.size < 3 || target_tokens.size > SPLIT_DECLARED_MAX_WORDS

      fields = payload["fields"].is_a?(Hash) ? payload["fields"] : {}
      return payload if field_text_matches_any?(fields["fanciful_name"], [ expected ])

      located = locate_split_tokens(target_tokens, pages)
      return payload if located.nil?

      prior = fields["fanciful_name"].is_a?(Hash) ? fields["fanciful_name"] : {}
      model_text = prior["model_text"].to_s.strip
      model_text = prior["text"].to_s.strip if model_text.empty?
      located = located.merge("text" => expected)
      located = located.merge("model_text" => model_text) if !model_text.empty? && model_text != expected
      payload.merge("fields" => fields.merge("fanciful_name" => located))
    end

    def reconcile_class_type_designation(payload:, pages:, application:, threshold:)
      expected = application.declared_class_type.to_s
      return payload if expected.strip.empty?

      candidates = [ expected, *class_type_aliases(application) ].uniq
      refined = reconcile_declared(
        payload: payload, pages: pages, field: "class_type_designation",
        expected: expected, threshold: threshold
      )
      fields = refined["fields"].is_a?(Hash) ? refined["fields"] : {}
      return refined if field_text_matches_any?(fields["class_type_designation"], candidates)

      candidates.drop(1).each do |candidate|
        refined = reconcile_declared(
          payload: refined, pages: pages, field: "class_type_designation",
          expected: candidate, threshold: threshold
        )
        fields = refined["fields"].is_a?(Hash) ? refined["fields"] : {}
        return refined if field_text_matches_any?(fields["class_type_designation"], [ candidate ])
      end

      reconcile_recognized_class_type(payload: refined, pages: pages, application: application)
    end

    def reconcile_recognized_class_type(payload:, pages:, application:)
      fields = payload["fields"].is_a?(Hash) ? payload["fields"] : {}
      return payload if fields.dig("class_type_designation", "text").to_s.strip.present?

      located = locate_recognized_class_type(pages, application)
      return payload if located.nil?

      payload.merge("fields" => fields.merge("class_type_designation" => located))
    end

    def reconcile_varietals(payload:, pages:, application:, threshold:)
      existing = Array(payload["varietals"])
      additions = Array(application.varietals).filter_map do |varietal|
        tokens = BboxGrounder.tokenize(varietal)
        next if tokens.empty?

        located = locate(tokens, pages, threshold)
        next if located.nil?

        located
      end
      merged = merge_unique_fields(existing + additions)
      payload.merge("varietals" => merged)
    end

    # For values printed inside a longer statement ("PRODUCT OF SCOTLAND"
    # for country "Scotland"): the parent line is the field value.
    def reconcile_statement_field(payload:, pages:, field:, expected:, threshold:)
      target_tokens = BboxGrounder.tokenize(expected)
      return payload if target_tokens.empty?

      fields = payload["fields"].is_a?(Hash) ? payload["fields"] : {}
      return payload if fields.dig(field, "text").to_s.strip.present?

      located = locate_statement(target_tokens, pages, threshold)
      return payload if located.nil?

      payload.merge("fields" => fields.merge(field => located))
    end

    # Operation verbs that open a name/address statement; "<verb> by"
    # locates the statement line even when the printed company name does
    # not match the application's.
    OPERATION_VERBS = %w[
      bottled produced imported brewed distilled vinted blended canned
      packed filled manufactured made prepared
    ].freeze

    # Search the OCR words for a name/address statement: first for the
    # applicant's (suffix-stripped) name, then for a statement-shaped line
    # ("<verb> by ..."). A model statement is trusted only if it names the
    # applicant; otherwise OCR can replace a confidently-read but wrong
    # statement such as a producer/bottler line when an importer line is
    # printed nearby.
    def reconcile_name_address(payload:, pages:, expected:, threshold:)
      fields = payload["fields"].is_a?(Hash) ? payload["fields"] : {}
      existing = fields.dig("name_address_statement", "text").to_s.strip
      if existing.present? && (expected.to_s.strip.empty? || applicant_statement_matches?(expected, existing))
        slot = fields["name_address_statement"].is_a?(Hash) ? fields["name_address_statement"] : { "text" => existing }
        trimmed = trim_name_address_statement(slot, expected)
        return payload if trimmed["text"] == slot["text"]

        return payload.merge("fields" => fields.merge("name_address_statement" => trimmed))
      end

      # NameAddress tokens are TextNormalizer-lowercase; the grounder's
      # normalization is uppercase, so align before matching.
      name_tokens = Parsing::NameAddress.name_tokens(Parsing::NameAddress.parse(expected).name).map(&:upcase)
      located = name_tokens.empty? ? nil : locate_statement_with_continuation(name_tokens, pages, threshold)
      located ||= locate_by_phrase(pages)
      return payload if located.nil?

      located = trim_name_address_statement(located, expected)
      payload.merge(
        "fields" => fields.merge("name_address_statement" => located)
      )
    end

    def locate(target_tokens, pages, threshold)
      Array(pages).each do |page|
        matched = BboxGrounder.best_match(target_tokens, page.words, threshold)
        next if matched.nil?

        # An entry that is exactly its one token keeps its printed form;
        # a token matched inside a longer line-level entry falls back to
        # its normalized form, since the sub-line verbatim text is not
        # recoverable from line geometry.
        parents = matched.map(&:first).uniq
        text = if parents.one? && BboxGrounder.normalize(parents.first.text) == target_tokens.join(" ")
          parents.first.text
        else
          matched.map do |word, token|
            BboxGrounder.normalize(word.text) == token ? word.text : token
          end.join(" ")
        end

        return located_slot(text, parents, page)
      end

      nil
    end

    def locate_recognized_class_type(pages, application)
      rules = Rules::Data.for(application.beverage_type)

      Array(pages).each do |page|
        max_length = [ CLASS_TYPE_WINDOW_WORDS, page.words.size ].min
        max_length.downto(1) do |length|
          page.words.each_index do |index|
            next if index + length > page.words.length

            words = page.words[index, length]
            next unless same_line_words?(words)

            text = words.map(&:text).join(" ")
            next unless recognized_class_type_text?(text, rules)

            return located_slot(text, words, page)
          end
        end
      end

      nil
    end

    def recognized_class_type_text?(text, rules)
      return false if text.match?(CLASS_TYPE_CONTEXT_BLOCKLIST)

      !Rules::Checks::Designation.lookup(text, rules).nil?
    end

    def same_line_words?(words)
      return true if words.one?

      boxes = words.map { |word| word_box(word) }
      return false if boxes.any?(&:nil?)

      first = boxes.first
      boxes.all? do |box|
        center_delta = ((first.y + (first.height / 2.0)) - (box.y + (box.height / 2.0))).abs
        tolerance = [ first.height, box.height ].max * Extraction::OcrEvidenceStore::LINE_CENTER_TOLERANCE
        center_delta <= tolerance
      end
    end

    def word_box(word)
      return word.bbox if word.respond_to?(:bbox)

      x = Integer(word.x, exception: false)
      y = Integer(word.y, exception: false)
      width = Integer(word.width, exception: false)
      height = Integer(word.height, exception: false)
      return nil if [ x, y, width, height ].any?(&:nil?)

      Extraction::OcrEvidenceStore::Bbox.new(x: x, y: y, width: width, height: height)
    end

    def locate_split_tokens(target_tokens, pages)
      Array(pages).each do |page|
        remaining = target_tokens.tally
        matched_words = matching_declared_token_spans(page.words, remaining)
        next unless remaining.values.all?(&:zero?)
        next if matched_words.empty?

        bbox = BboxGrounder.union_bbox(matched_words)
        next if bbox[3] > page.height * SPLIT_DECLARED_MAX_HEIGHT_RATIO

        return located_slot(matched_words.map(&:text).join(" "), matched_words, page)
      end

      nil
    end

    def matching_declared_token_spans(words, remaining)
      Array(words).select do |word|
        word_tokens = BboxGrounder.tokenize(word.text)
        next false if word_tokens.empty?

        matched = word_tokens.select { |token| remaining.fetch(token, 0).positive? }
        next false if matched.empty?

        matched.each { |token| remaining[token] -= 1 }
        true
      end
    end

    # Finds a "<verb> by" line and carries its immediate continuation
    # lines (vertically adjacent below it) - addresses usually wrap.
    def locate_by_phrase(pages)
      Array(pages).each do |page|
        index = page.words.index do |word|
          normalized = BboxGrounder.normalize(word.text)
          OPERATION_VERBS.any? { |verb| normalized.include?("#{verb.upcase} BY") }
        end
        next if index.nil?

        lines = statement_lines_from(page, index)

        return located_slot(lines.map(&:text).join(" "), lines, page)
      end

      nil
    end

    # Like locate, but the field text is the matched parents' full printed
    # text: for a statement, the surrounding line is the value, not just
    # the matched name inside it.
    def locate_statement(target_tokens, pages, threshold)
      Array(pages).each do |page|
        matched = BboxGrounder.best_match(target_tokens, page.words, threshold)
        next if matched.nil?

        parents = matched.map(&:first).uniq
        return located_slot(parents.map(&:text).join(" "), parents, page)
      end

      nil
    end

    def locate_statement_with_continuation(target_tokens, pages, threshold)
      Array(pages).each do |page|
        matched = BboxGrounder.best_match(target_tokens, page.words, threshold)
        next if matched.nil?

        parents = matched.map(&:first).uniq
        index = page.words.index(parents.first)
        lines = index.nil? ? parents : statement_lines_from(page, index)
        return located_slot(lines.map(&:text).join(" "), lines, page)
      end

      nil
    end

    def statement_lines_from(page, index)
      lines = [ page.words[index] ]
      page.words[(index + 1)..].to_a.first(2).each do |word|
        previous = lines.last
        break unless word.y >= previous.y && (word.y - (previous.y + previous.height)) < previous.height * 1.5

        lines << word
        break if terminal_state_line?(word.text)
      end

      lines
    end

    # Every reconciliation path fills a slot the same way: the located
    # text, boxed by the union of its words in the page's raster basis.
    def located_slot(text, words, page)
      {
        "text" => text,
        "bbox" => BboxGrounder.union_bbox(words),
        "bbox_basis" => [ page.width, page.height ],
        "bbox_source" => "ocr",
        "page" => page.number,
        "confidence" => nil
      }
    end

    def class_type_aliases(application)
      rules = Rules::Data.for(application.beverage_type)
      declared = Parsing::TextNormalizer.normalize(application.declared_class_type)
      return [] if declared.empty?

      Array(rules.dig("designations", "entries")).flat_map { |entry| entry["names"] }.select do |name|
        normalized = Parsing::TextNormalizer.normalize(name)
        normalized != declared && declared.include?(normalized)
      end
    end

    def field_text_matches_any?(field, expected_values)
      text = field.is_a?(Hash) ? field["text"] : field
      expected_values.any? { |expected| Parsing::TextNormalizer.equivalent?(expected, text) }
    end

    def applicant_statement_matches?(expected, extracted)
      Rules::Checks::Identity.applicant_presence(expected, extracted) == :present
    end

    def terminal_state_line?(text)
      !Parsing::NameAddress.find_state(Parsing::TextNormalizer.normalize(text).split(" ")).nil?
    end

    def trim_name_address_statement(located, expected)
      parts = Parsing::NameAddress.parse(expected)
      return located if parts.state.nil?

      text = located["text"].to_s
      tokens = text.split(/\s+/)
      normalized_tokens = tokens.map { |token| Parsing::TextNormalizer.normalize(token) }
      trim_at = name_address_trim_index(normalized_tokens, parts)
      return located if trim_at.nil? || trim_at >= tokens.size - 1

      located.merge("text" => tokens[0..trim_at].join(" "))
    end

    def name_address_trim_index(tokens, parts)
      city_tokens = Parsing::TextNormalizer.normalize(parts.city).split(" ")

      tokens.each_index do |index|
        state_token_options(parts.state).each do |state_tokens|
          next unless tokens[index, state_tokens.size] == state_tokens
          city_start = index - city_tokens.size
          next if city_start.negative? && city_tokens.present?
          next unless city_tokens.empty? || tokens[city_start, city_tokens.size] == city_tokens

          return index + state_tokens.size - 1
        end
      end

      nil
    end

    def state_token_options(abbreviation)
      full_name = Parsing::NameAddress::US_STATES.key(abbreviation)
      [ [ abbreviation ], Parsing::TextNormalizer.normalize(full_name).split(" ") ].select(&:present?)
    end

    def merge_unique_fields(fields)
      fields.each_with_object([]) do |field, unique|
        text = field.is_a?(Hash) ? field["text"] : field
        normalized = Parsing::TextNormalizer.normalize(text)
        next if normalized.empty?
        next if unique.any? { |existing| Parsing::TextNormalizer.normalize(existing["text"]) == normalized }

        unique << field
      end
    end
  end
end
