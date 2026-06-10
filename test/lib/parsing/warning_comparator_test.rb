# frozen_string_literal: true

require "test_helper"

module Parsing
  class WarningComparatorTest < ActiveSupport::TestCase
    STATUTORY = "GOVERNMENT WARNING: (1) According to the Surgeon General, women should not drink " \
                "alcoholic beverages during pregnancy because of the risk of birth defects. " \
                "(2) Consumption of alcoholic beverages impairs your ability to drive a car or " \
                "operate machinery, and may cause health problems."

    test "exact statutory text matches with caps prefix" do
      result = WarningComparator.compare(STATUTORY, STATUTORY)
      assert result.text_matches
      assert result.prefix_all_caps
      assert_empty result.missing_words
    end

    test "whole-statement caps is acceptable text-wise" do
      result = WarningComparator.compare(STATUTORY.upcase, STATUTORY)
      assert result.text_matches
      assert result.prefix_all_caps
    end

    test "title-case prefix fails the caps check but not the words check" do
      extracted = STATUTORY.sub("GOVERNMENT WARNING:", "Government Warning:")
      result = WarningComparator.compare(extracted, STATUTORY)
      assert result.text_matches
      assert_not result.prefix_all_caps
    end

    test "re-worded warnings fail with missing words reported" do
      extracted = STATUTORY.sub("birth defects", "health issues")
      result = WarningComparator.compare(extracted, STATUTORY)
      assert_not result.text_matches
      assert_includes result.missing_words, "birth"
      assert_includes result.extra_words, "issues"
    end

    test "dropped clause fails" do
      extracted = STATUTORY.split("(2)").first
      result = WarningComparator.compare(extracted, STATUTORY)
      assert_not result.text_matches
      assert_includes result.missing_words, "machinery"
    end

    test "line breaks within the text do not affect word matching" do
      extracted = STATUTORY.gsub(", women", ",\nwomen")
      assert WarningComparator.compare(extracted, STATUTORY).text_matches
    end

    test "missing warning fails everything" do
      result = WarningComparator.compare(nil, STATUTORY)
      assert_not result.text_matches
      assert_not result.prefix_all_caps
    end

    test "smart quotes normalize to plain quotes" do
      extracted = STATUTORY.sub("Surgeon General", "Surgeon General")
      result = WarningComparator.compare(extracted, STATUTORY)
      assert result.text_matches
    end
  end
end
