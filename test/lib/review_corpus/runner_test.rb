# frozen_string_literal: true

require "test_helper"

class ReviewCorpusRunnerTest < ActiveSupport::TestCase
  test "fixture corpus passes deterministic expectations" do
    result = ReviewCorpus::Runner.new(
      fixtures_dir: Rails.root.join("test/fixtures/review_corpus")
    ).run

    assert_equal 3, result.dig(:summary, :cases)
    assert_equal 3, result.dig(:summary, :passed), result.fetch(:cases).inspect
    assert_equal 0, result.dig(:summary, :failed), result.fetch(:cases).inspect
    assert_operator result.dig(:summary, :duration_ms, :p95), :>=, 0
  end
end
