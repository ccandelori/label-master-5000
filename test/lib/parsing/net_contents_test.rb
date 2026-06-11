# frozen_string_literal: true

require "test_helper"

module Parsing
  class NetContentsTest < ActiveSupport::TestCase
    test "parses metric statements" do
      result = NetContents.parse("750 mL")
      assert_equal 750.0, result.milliliters
      assert_predicate result, :metric?
    end

    test "parses liters and centiliters" do
      assert_equal 1000.0, NetContents.parse("1 Liter").milliliters
      assert_equal 1500.0, NetContents.parse("1.5 L").milliliters
      assert_equal 750.0, NetContents.parse("75 cl").milliliters
    end

    test "parses fluid ounces as US customary" do
      result = NetContents.parse("12 fl. oz.")
      assert_in_delta 354.88, result.milliliters, 0.01
      assert_predicate result, :us_customary?
    end

    test "parses pints, quarts, gallons" do
      assert_in_delta 473.18, NetContents.parse("1 pint").milliliters, 0.01
      assert_in_delta 946.35, NetContents.parse("1 quart").milliliters, 0.01
      assert_in_delta 3785.41, NetContents.parse("1 gallon").milliliters, 0.01
    end

    test "parses compound American statements" do
      result = NetContents.parse("1 pint, 4 fl oz")
      assert_in_delta 473.18 + 118.29, result.milliliters, 0.05
      assert_predicate result, :us_customary?
    end

    test "parses bare and mixed fractions" do
      assert_in_delta 946.35 * 0.8, NetContents.parse("4/5 quart").milliliters, 0.05
      assert_in_delta 3785.41 * 1.25, NetContents.parse("1 1/4 gallons").milliliters, 0.05
      assert_in_delta 236.59, NetContents.parse("1/2 pint").milliliters, 0.05
    end

    test "rejects mixed measurement systems" do
      assert_nil NetContents.parse("1 pint 500 ml")
    end

    test "a parenthetical restatement is the same volume said twice" do
      result = NetContents.parse("1 Pint (16 fl oz)")
      assert_in_delta 473.18, result.milliliters, 0.01
      assert_predicate result, :us_customary?
    end

    test "a fused-token restatement without parentheses still counts once" do
      result = NetContents.parse("1PINT 16FLOZ")
      assert_in_delta 473.18, result.milliliters, 0.01
      assert_predicate result, :us_customary?
    end

    test "a cross-system restatement keeps the primary statement's system" do
      result = NetContents.parse("750 mL (25.4 FL OZ)")
      assert_equal 750.0, result.milliliters
      assert_predicate result, :metric?
    end

    test "compound additions remain additive - only equal volumes restate" do
      assert_in_delta 591.47, NetContents.parse("1 pint, 4 fl oz").milliliters, 0.05
    end

    test "returns nil for unparseable input" do
      assert_nil NetContents.parse(nil)
      assert_nil NetContents.parse("")
      assert_nil NetContents.parse("a generous pour")
      assert_nil NetContents.parse("750 parsecs")
    end

    test "740 mL parses fine - validity is the rules engine's call" do
      assert_equal 740.0, NetContents.parse("740 mL").milliliters
    end
  end
end
