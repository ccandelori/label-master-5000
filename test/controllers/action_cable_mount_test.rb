# frozen_string_literal: true

require "test_helper"

class ActionCableMountTest < ActionDispatch::IntegrationTest
  test "cable endpoint is mounted for live Turbo updates" do
    assert Rails.application.routes.routes.any? { |route| action_cable_route?(route) }
  end

  private

  def action_cable_route?(route)
    route.path.spec.to_s == "/cable" && route.app.app == ActionCable.server
  rescue NoMethodError
    false
  end
end
