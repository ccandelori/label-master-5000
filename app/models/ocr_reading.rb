# frozen_string_literal: true

# One artwork's OCR word pool, keyed by blob checksum and the engine
# configuration that produced it. OCR is deterministic for the same
# bytes, so re-verifications read from here instead of re-running the
# multi-pass page reads (the dominant cost of a verification).
class OcrReading < ApplicationRecord
  validates :blob_checksum, presence: true, uniqueness: { scope: :engine_key }
  validates :engine_key, presence: true
end
