# frozen_string_literal: true

module Parsing
  # Normalizes application-supplied sentinel values that mean the source
  # record has no comparable declaration for a field.
  module ApplicationValue
    NOT_STATED_PATTERNS = [
      /\Anot stated on application\z/i,
      /\Anot stated\z/i,
      /\An\/a\z/i
    ].freeze

    module_function

    def not_stated?(value)
      text = value.to_s.strip
      return false if text.empty?

      NOT_STATED_PATTERNS.any? { |pattern| text.match?(pattern) }
    end
  end
end
