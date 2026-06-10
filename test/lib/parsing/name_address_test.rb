# frozen_string_literal: true

require "test_helper"

class NameAddressTest < ActiveSupport::TestCase
  test "parses name, city, and abbreviated state" do
    parts = Parsing::NameAddress.parse("Old Tom Distilling Co., Bardstown, KY")

    assert_equal "old tom distilling co", parts.name
    assert_equal "bardstown", parts.city
    assert_equal "ky", parts.state
  end

  test "parses a street address and ZIP without mistaking them for the place" do
    parts = Parsing::NameAddress.parse("Proof Artisan Distillers LLC, 123 Main St, Fargo, ND 58102")

    assert_equal "proof artisan distillers llc", parts.name
    assert_equal "fargo", parts.city
    assert_equal "nd", parts.state
  end

  test "parses a full state name and a city-state segment" do
    parts = Parsing::NameAddress.parse("Lone Star Spirits, Houston Texas")

    assert_equal "houston", parts.city
    assert_equal "tx", parts.state
  end

  test "does not treat a trailing entity suffix as Colorado" do
    parts = Parsing::NameAddress.parse("Acme Brewing Co")

    assert_nil parts.state
    assert_equal "acme brewing co", parts.name
  end

  test "two-word state names parse with their city" do
    parts = Parsing::NameAddress.parse("Empire Wines, Buffalo, New York")

    assert_equal "buffalo", parts.city
    assert_equal "ny", parts.state
  end

  test "name_tokens strips trailing entity suffixes but never the whole name" do
    assert_equal %w[old tom distilling], Parsing::NameAddress.name_tokens("Old Tom Distilling Co.")
    assert_equal %w[proof artisan distillers], Parsing::NameAddress.name_tokens("Proof Artisan Distillers, LLC")
    assert_equal %w[llc], Parsing::NameAddress.name_tokens("LLC")
  end

  test "state_present? matches abbreviation or full name as tokens only" do
    tokens = "bottled in fargo north dakota for stripper vodka".split(" ")
    assert Parsing::NameAddress.state_present?(tokens, "nd")

    brandy = "fine brandy from somewhere".split(" ")
    assert_not Parsing::NameAddress.state_present?(brandy, "nd"),
               "nd inside brandy must not count"
  end

  test "tokens_include? requires consecutive tokens" do
    tokens = "bottled by acme in new orleans louisiana".split(" ")
    assert Parsing::NameAddress.tokens_include?(tokens, "New Orleans")
    assert_not Parsing::NameAddress.tokens_include?(tokens, "orleans new")
  end
end
