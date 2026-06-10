# frozen_string_literal: true

require "test_helper"

class RulesControllerTest < ActionDispatch::IntegrationTest
  test "the rules reference renders the loaded rule data" do
    get rules_path
    assert_response :success
    assert_match(/GOVERNMENT WARNING:/, response.body)
    assert_match(/Malt beverages/, response.body)
    assert_match(/Wine/, response.body)
    assert_match(/Spirits/, response.body)
  end
end
