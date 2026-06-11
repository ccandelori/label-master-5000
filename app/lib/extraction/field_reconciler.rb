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
      "class_type_designation" => :declared_class_type,
      "appellation" => :appellation,
      "vintage" => :vintage_year,
      "net_contents" => :net_contents
    }.freeze

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
      refined = reconcile_statement_field(
        payload: refined, pages: pages, field: "country_of_origin_statement",
        expected: application.country_of_origin.to_s, threshold: threshold
      )
      reconcile_name_address(
        payload: refined, pages: pages,
        expected: application.applicant_name_address, threshold: threshold
      )
    end

    # Locates one declared value and replaces the field slot on a hit.
    def reconcile_declared(payload:, pages:, field:, expected:, threshold:)
      target_tokens = BboxGrounder.tokenize(expected)
      return payload if target_tokens.empty?

      located = locate(target_tokens, pages, threshold)
      return payload if located.nil?

      fields = payload["fields"].is_a?(Hash) ? payload["fields"] : {}
      payload.merge("fields" => fields.merge(field => located))
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

    # When the model found no name/address statement at all, search the
    # OCR words: first for the applicant's (suffix-stripped) name, then
    # for a statement-shaped line ("<verb> by ..."). Line-level OCR makes
    # the matched parents the statement itself, so their text fills the
    # slot and the rules judge it as usual - a label naming a different
    # company surfaces as a name mismatch instead of a missing statement.
    # A statement the model DID read is never second-guessed.
    def reconcile_name_address(payload:, pages:, expected:, threshold:)
      fields = payload["fields"].is_a?(Hash) ? payload["fields"] : {}
      return payload if fields.dig("name_address_statement", "text").to_s.strip.present?

      # NameAddress tokens are TextNormalizer-lowercase; the grounder's
      # normalization is uppercase, so align before matching.
      name_tokens = Parsing::NameAddress.name_tokens(Parsing::NameAddress.parse(expected).name).map(&:upcase)
      located = name_tokens.empty? ? nil : locate_statement(name_tokens, pages, threshold)
      located ||= locate_by_phrase(pages)
      return payload if located.nil?

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
        text = matched.map do |word, token|
          BboxGrounder.normalize(word.text) == token ? word.text : token
        end.join(" ")

        return located_slot(text, matched.map(&:first).uniq, page)
      end

      nil
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

        lines = [ page.words[index] ]
        page.words[(index + 1)..].to_a.first(2).each do |word|
          previous = lines.last
          break unless word.y >= previous.y && (word.y - (previous.y + previous.height)) < previous.height * 1.5

          lines << word
        end

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
  end
end
