# frozen_string_literal: true

require "securerandom"
require "test_helper"

class PerformanceOcrSidecarStressTest < ActiveSupport::TestCase
  class StubClient
    def read(data:, content_type:)
      [
        Extraction::OcrClient::Page.new(
          number: 1,
          width: 20,
          height: 20,
          words: [
            Extraction::OcrClient::Word.new(text: "HELLO", x: 1, y: 2, width: 3, height: 4)
          ]
        )
      ]
    end
  end

  test "runs real records through the Paddle client and writes a stress artifact" do
    batch = Batch.create!(name: "OCR stress batch", total_rows: 1)
    application = LabelApplication.new(
      batch: batch,
      row_number: 1,
      serial_number: "OCR-STRESS-1",
      beverage_type: "malt",
      brand_name: "OCR STRESS BRAND",
      applicant_name_address: "Stress Brewing, Portland, OR",
      alcohol_content: 6.0,
      net_contents: "12 fl oz"
    )
    application.artwork.attach(io: StringIO.new("stress-bytes"), filename: "label.png", content_type: "image/png")
    application.save!
    output_dir = Rails.root.join("tmp", "ocr-stress-test-#{Process.pid}-#{SecureRandom.hex(4)}")

    result = Performance::OcrSidecarStress.new(
      batch_id: batch.id,
      limit: "1",
      output_dir: output_dir,
      client: StubClient.new
    ).run
    artifact = Pathname(result.fetch(:artifact_path))
    persisted = JSON.parse(artifact.read)

    assert artifact.exist?
    assert_equal 1, persisted.dig("summary", "labels")
    assert_equal 1, persisted.dig("summary", "successes")
    assert_equal 0, persisted.dig("summary", "backpressure_failures")
    assert_equal({}, persisted.dig("summary", "error_classes"))
    assert_equal 1, persisted.dig("summary", "word_count", "total")
    assert_equal [ application.id ], persisted.dig("scope", "label_application_ids")
  end
end
