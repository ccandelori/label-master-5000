# frozen_string_literal: true

module EvalCorpus
  # Chooses front/back artwork from the registry's imperfect attachment
  # metadata. The TTB form's Image Type text is useful but not authoritative:
  # real forms sometimes contradict the uploaded filename. Filename cues are
  # therefore stronger, and contradictory evidence cancels toward the other
  # side instead of being silently trusted.
  module ArtworkRoleResolver
    IMAGE_EXTENSIONS = /\.(jpe?g|png|webp)\z/i
    FRONT_WORDS = %w[front frt brand face collar].freeze
    BACK_WORDS = %w[back bck rear retro].freeze
    SHORT_BACK_WORDS = %w[bk].freeze
    METADATA_WEIGHT = 2
    FILENAME_WEIGHT = 3

    Candidate = Data.define(:attachment, :index, :front_score, :back_score)

    module_function

    def pick_front_back(attachments)
      candidates = raster_attachments(attachments).each_with_index.map do |attachment, index|
        Candidate.new(
          attachment: attachment, index: index,
          front_score: score(attachment, FRONT_WORDS, :front),
          back_score: score(attachment, BACK_WORDS, :back)
        )
      end
      return [ nil, nil ] if candidates.empty?

      front = front_candidate(candidates)
      back = back_candidate(candidates, front)
      [ front&.attachment, back&.attachment ]
    end

    def filename_role(attachment)
      text = filename_text(attachment)
      return nil if text.empty?

      front = contains_any?(text, FRONT_WORDS)
      back = contains_any?(text, BACK_WORDS) || contains_exact_token?(text, SHORT_BACK_WORDS)
      return nil if front == back

      front ? :front : :back
    end

    def role_conflict?(attachment)
      meta = metadata_role(attachment)
      filename = filename_role(attachment)
      !meta.nil? && !filename.nil? && meta != filename
    end

    def raster_attachments(attachments)
      Array(attachments).select { |attachment| raster?(attachment) }
    end

    def raster?(attachment)
      filename_text(attachment).match?(IMAGE_EXTENSIONS)
    end

    def front_candidate(candidates)
      with_role = candidates.select { |candidate| candidate.front_score.positive? || candidate.back_score.positive? }
      return candidates.first if with_role.empty?

      with_role.max_by do |candidate|
        [ candidate.front_score - candidate.back_score, candidate.front_score, -candidate.index ]
      end
    end

    def back_candidate(candidates, front)
      remaining = candidates.reject { |candidate| candidate == front }
      return nil if remaining.empty?

      candidate = remaining.max_by do |entry|
        [ entry.back_score - entry.front_score, entry.back_score, -entry.index ]
      end
      return nil if candidate.back_score <= candidate.front_score || candidate.back_score.zero?

      candidate
    end

    def score(attachment, words, role)
      score = 0
      score += FILENAME_WEIGHT if contains_any?(filename_text(attachment), words)
      score += FILENAME_WEIGHT if role == :back && contains_exact_token?(filename_text(attachment), SHORT_BACK_WORDS)
      score += METADATA_WEIGHT if metadata_role(attachment) == role
      score
    end

    def metadata_role(attachment)
      text = metadata_text(attachment)
      return nil if text.empty?

      front = contains_any?(text, FRONT_WORDS)
      back = contains_any?(text, BACK_WORDS) || contains_exact_token?(text, SHORT_BACK_WORDS)
      return nil if front == back

      front ? :front : :back
    end

    def contains_any?(text, words)
      normalized = normalize(text)
      words.any? { |word| normalized.include?(word) }
    end

    def contains_exact_token?(text, words)
      tokens = normalize(text).split
      words.any? { |word| tokens.include?(word) }
    end

    def metadata_text(attachment)
      value_for(attachment, :image_type) || value_for(attachment, :kind) || ""
    end

    def filename_text(attachment)
      filename = value_for(attachment, :filename) || value_for(attachment, :local_file)
      filename ||= value_for(attachment, :path).to_s[/filename=([^&]+)/, 1]
      filename.to_s
    end

    def normalize(text)
      text.to_s.downcase.gsub(/[^a-z0-9]+/, " ")
    end

    def value_for(attachment, key)
      if attachment.respond_to?(key)
        attachment.public_send(key)
      elsif attachment.respond_to?(:[])
        attachment[key.to_s] || attachment[key]
      end
    end
  end
end
