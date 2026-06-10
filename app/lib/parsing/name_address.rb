# frozen_string_literal: true

module Parsing
  # Splits an application's applicant name-and-address string into the
  # parts the regulations actually require on the label: the name and the
  # place of business (city and state). Street address and ZIP are
  # application detail the label may legitimately omit (27 CFR 4.35, 5.66,
  # 7.66: name plus city and state suffice).
  module NameAddress
    Parts = Data.define(:name, :city, :state)

    US_STATES = {
      "alabama" => "al", "alaska" => "ak", "arizona" => "az", "arkansas" => "ar",
      "california" => "ca", "colorado" => "co", "connecticut" => "ct", "delaware" => "de",
      "florida" => "fl", "georgia" => "ga", "hawaii" => "hi", "idaho" => "id",
      "illinois" => "il", "indiana" => "in", "iowa" => "ia", "kansas" => "ks",
      "kentucky" => "ky", "louisiana" => "la", "maine" => "me", "maryland" => "md",
      "massachusetts" => "ma", "michigan" => "mi", "minnesota" => "mn", "mississippi" => "ms",
      "missouri" => "mo", "montana" => "mt", "nebraska" => "ne", "nevada" => "nv",
      "new hampshire" => "nh", "new jersey" => "nj", "new mexico" => "nm", "new york" => "ny",
      "north carolina" => "nc", "north dakota" => "nd", "ohio" => "oh", "oklahoma" => "ok",
      "oregon" => "or", "pennsylvania" => "pa", "rhode island" => "ri", "south carolina" => "sc",
      "south dakota" => "sd", "tennessee" => "tn", "texas" => "tx", "utah" => "ut",
      "vermont" => "vt", "virginia" => "va", "washington" => "wa", "west virginia" => "wv",
      "wisconsin" => "wi", "wyoming" => "wy", "district of columbia" => "dc", "puerto rico" => "pr"
    }.freeze
    STATE_ABBREVIATIONS = US_STATES.values.to_set.freeze

    # Trailing organization-form words an applicant name carries on the
    # application but a label need not repeat.
    ENTITY_SUFFIXES = %w[
      llc inc co corp ltd lp llp plc company incorporated corporation limited
    ].to_set.freeze

    module_function

    # Parses "Name[, Street], City, ST[ ZIP]" shapes from the application.
    # Total: when no US state can be located, returns the whole normalized
    # string as the name with city and state nil - callers fall back to
    # plain name matching.
    def parse(text)
      segments = text.to_s.split(",").map { |s| TextNormalizer.normalize(s) }.reject(&:empty?)
      return Parts.new(name: TextNormalizer.normalize(text), city: nil, state: nil) if segments.empty?

      # The first segment is the applicant name and never yields the
      # state: "Acme Brewing Co" ends in an entity suffix, not Colorado.
      # A string without comma structure therefore parses as name-only.
      segments.each_index.reverse_each do |index|
        break if index.zero?

        tokens = segments[index].split(" ")
        state_at = find_state(tokens)
        next if state_at.nil?

        city_tokens = tokens[0...state_at.first]
        city = city_tokens.empty? ? previous_city(segments, index) : city_tokens.join(" ")
        return Parts.new(name: segments.first, city: city, state: state_at.last)
      end

      Parts.new(name: TextNormalizer.normalize(text), city: nil, state: nil)
    end

    # Token sequence of the name with trailing entity-form words removed:
    # "old tom distilling co" -> ["old", "tom", "distilling"].
    def name_tokens(name)
      tokens = TextNormalizer.normalize(name).split(" ")
      tokens.pop while tokens.size > 1 && ENTITY_SUFFIXES.include?(tokens.last)
      tokens
    end

    # True when the normalized haystack contains the needle as a
    # consecutive token run - "nd" must match the token, never the
    # substring inside "brandy".
    def tokens_include?(haystack_tokens, needle)
      needle_tokens = TextNormalizer.normalize(needle).split(" ")
      return false if needle_tokens.empty? || haystack_tokens.size < needle_tokens.size

      haystack_tokens.each_cons(needle_tokens.size).any? { |run| run == needle_tokens }
    end

    # True when the statement names the state by abbreviation or in full.
    def state_present?(haystack_tokens, abbreviation)
      return true if haystack_tokens.include?(abbreviation)

      full_name = US_STATES.key(abbreviation)
      !full_name.nil? && tokens_include?(haystack_tokens, full_name)
    end

    # Locates a state within a segment's tokens; returns [index, abbrev]
    # or nil. A state must close its segment (optionally followed by a
    # ZIP) - "co" in "acme brewing co" is an entity suffix, not Colorado.
    # Two-token full names ("north dakota") are checked before single
    # tokens so the abbreviation scan cannot split them.
    def find_state(tokens)
      tokens.each_cons(2).with_index do |pair, index|
        abbreviation = US_STATES[pair.join(" ")]
        return [ index, abbreviation ] if abbreviation && terminal?(tokens, index + 2)
      end

      tokens.each_with_index do |token, index|
        next unless terminal?(tokens, index + 1)
        return [ index, token ] if STATE_ABBREVIATIONS.include?(token)
        return [ index, US_STATES[token] ] if US_STATES.key?(token)
      end

      nil
    end

    # True when everything after position is ZIP-like digit runs.
    def terminal?(tokens, position)
      tokens[position..].all? { |token| token.match?(/\A\d+\z/) }
    end

    # The city for a bare-state segment ("ND 58102") is the previous
    # segment, minus any ZIP-like digit runs.
    def previous_city(segments, state_index)
      return nil if state_index.zero?

      city = segments[state_index - 1].gsub(/\b\d{5,}\b/, "").squeeze(" ").strip
      city.empty? ? nil : city
    end
  end
end
