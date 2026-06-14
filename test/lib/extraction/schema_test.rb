# frozen_string_literal: true

require "test_helper"

class ExtractionSchemaTest < ActiveSupport::TestCase
  test "located field schema does not ask VLMs for bounding boxes" do
    field_schema = Extraction::Schema::RESPONSE_SCHEMA.dig("$defs", "located_field")

    assert_nil field_schema.dig("properties", "bbox")
    assert_not_includes field_schema["required"], "bbox"
  end
end
