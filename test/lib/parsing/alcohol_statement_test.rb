# frozen_string_literal: true

require "test_helper"

module Parsing
  class AlcoholStatementTest < ActiveSupport::TestCase
    test "parses percent with proof" do
      result = AlcoholStatement.parse("45% Alc./Vol. (90 Proof)")
      assert_equal 45.0, result.percent
      assert_equal 90.0, result.proof
      assert_not result.range?
    end

    test "parses the prescribed wine forms" do
      assert_equal 14.1, AlcoholStatement.parse("ALC. 14.1% BY VOL.").percent
      assert_equal 12.5, AlcoholStatement.parse("Alcohol 12.5% by volume").percent
    end

    test "parses range statements" do
      result = AlcoholStatement.parse("9% TO 12% ALC. BY VOL.")
      assert result.range?
      assert_equal [ 9.0, 12.0 ], result.range
      assert_nil result.percent
    end

    test "parses hyphenated ranges" do
      assert_equal [ 17.0, 19.0 ], AlcoholStatement.parse("17%-19% ALC. BY VOL.").range
    end

    test "detects bottled-at form for products with solids" do
      result = AlcoholStatement.parse("BOTTLED AT 48% ALC. BY VOL.")
      assert result.bottled_at
      assert_equal 48.0, result.percent
    end

    test "proof-only statements still parse" do
      result = AlcoholStatement.parse("90 PROOF")
      assert_nil result.percent
      assert_equal 90.0, result.proof
    end

    test "returns nil for text without a statement" do
      assert_nil AlcoholStatement.parse(nil)
      assert_nil AlcoholStatement.parse("")
      assert_nil AlcoholStatement.parse("Kentucky Straight Bourbon Whiskey")
    end

    test "statement? finds alcohol statements among label fields" do
      assert AlcoholStatement.statement?("45% ALC/VOL")
      assert AlcoholStatement.statement?("Alcohol 12% by volume")
      assert_not AlcoholStatement.statement?("750 mL")
      assert_not AlcoholStatement.statement?("100% agave")
    end
  end
end
