require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # rack_test keeps system tests fast and dependency-free. The bounding-box
  # overlay and Turbo Stream live updates are JavaScript-driven and are not
  # exercised here; the happy path asserts server-rendered results.
  driven_by :rack_test

  # turbo-rails wraps #visit to wait for <turbo-cable-stream-source> elements
  # to report connected - that requires a JavaScript driver, so neutralize it.
  def connect_turbo_cable_stream_sources
  end
end
