# frozen_string_literal: true

require "test_helper"

module Parsing
  class TextNormalizerTest < ActiveSupport::TestCase
    test "erases casing differences" do
      assert TextNormalizer.equivalent?("STONE'S THROW", "Stone's Throw")
    end

    test "erases punctuation and whitespace differences" do
      assert TextNormalizer.equivalent?("Old Tom  Distillery", "Old-Tom Distillery")
      assert TextNormalizer.equivalent?("St. James Gate", "St James Gate")
    end

    test "erases diacritics" do
      assert TextNormalizer.equivalent?("Côte du Soleil Rosé", "Cote du Soleil Rose")
    end

    test "normalizes binary encoded text from imported sources" do
      binary_text = "KENTUCKY STRAIGHT BOURBON WHISKEY".b

      assert_equal "kentucky straight bourbon whiskey", TextNormalizer.normalize(binary_text)
      assert TextNormalizer.equivalent?("Kentucky Straight Bourbon Whiskey", binary_text)
    end

    test "replaces invalid bytes before normalization" do
      invalid_text = +"Bourbon\xFF Whiskey"
      invalid_text.force_encoding(Encoding::UTF_8)

      assert_equal "bourbon whiskey", TextNormalizer.normalize(invalid_text)
    end

    test "different names stay different" do
      assert_not TextNormalizer.equivalent?("Old Tom Distillery", "Old Tim Distillery")
      assert_not TextNormalizer.equivalent?("Stone's Throw", "Stones Throw Brewing")
    end

    test "blank input is never equivalent to anything" do
      assert_not TextNormalizer.equivalent?(nil, nil)
      assert_not TextNormalizer.equivalent?("", "")
      assert_not TextNormalizer.equivalent?(nil, "Old Tom")
    end

    test "equivalent_but_not_identical distinguishes exact from fuzzy matches" do
      assert TextNormalizer.equivalent_but_not_identical?("STONE'S THROW", "Stone's Throw")
      assert_not TextNormalizer.equivalent_but_not_identical?("Stone's Throw", "Stone's Throw")
    end

    test "equivalent? ignores spacing - letter-spaced display type matches" do
      assert TextNormalizer.equivalent?("V o D K A", "VODKA")
      assert TextNormalizer.equivalent?("D R A U G H T  S T O U T", "Draught Stout")
      assert_not TextNormalizer.equivalent?("VODKA", "VODA")
    end
  end
end
