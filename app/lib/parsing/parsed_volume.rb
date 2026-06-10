# frozen_string_literal: true

module Parsing
  # A net-contents quantity normalized to milliliters, retaining which
  # measurement system the statement used (the malt BAM requires American
  # measure; wine and spirits require metric standards of fill).
  ParsedVolume = Data.define(:milliliters, :unit_system, :raw) do
    def metric?
      unit_system == :metric
    end

    def us_customary?
      unit_system == :us_customary
    end
  end
end
