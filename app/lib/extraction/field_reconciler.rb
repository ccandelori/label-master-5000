# frozen_string_literal: true

module Extraction
  # Reconciles the fanciful_name field against the application's declared
  # value using local OCR geometry. The model frequently mistakes marketing
  # taglines for fanciful names while the declared name sits in plain type
  # elsewhere on the label; when the declared text is found among the OCR
  # words, the located text and its true box replace the model's guess, and
  # the rules comparison then passes on its own terms.
  #
  # Boundary note: the extraction call itself stays application-blind -
  # this runs after it, in the job, against Tesseract output that never
  # leaves the host. A miss changes nothing: the model's read stands and
  # the rules flag it as before. Pure and total, like BboxGrounder.
  module FieldReconciler
    module_function

    # payload: the extraction JSON; pages: Array of OcrClient::Page;
    # expected: the application's declared fanciful name (nil/blank skips);
    # threshold: minimum fuzzy similarity, shared with bbox grounding.
    def reconcile_fanciful_name(payload:, pages:, expected:, threshold:)
      target_tokens = BboxGrounder.tokenize(expected)
      return payload if target_tokens.empty?

      located = locate(target_tokens, pages, threshold)
      return payload if located.nil?

      fields = payload["fields"].is_a?(Hash) ? payload["fields"] : {}
      payload.merge(
        "fields" => fields.merge("fanciful_name" => located)
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

        return {
          "text" => text,
          "bbox" => BboxGrounder.union_bbox(matched.map(&:first).uniq),
          "bbox_basis" => [ page.width, page.height ],
          "bbox_source" => "ocr",
          "page" => page.number,
          "confidence" => nil
        }
      end

      nil
    end
  end
end
