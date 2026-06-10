# frozen_string_literal: true

# Pure generator for draft rejection notices: cited findings in, plain text
# out. No I/O and no clock - the timestamp comes from the decision. The
# framing is prototype-grade correspondence, not an official TTB form.
module RejectionNotice
  extend VerdictsHelper

  module_function

  def generate(application:, verification:)
    sections = [
      header(application, verification),
      findings_section(verification.field_checks),
      reviewer_note(verification),
      footer
    ].compact

    "#{sections.join("\n\n")}\n"
  end

  def header(application, verification)
    decided = verification.decided_at
    <<~TEXT.strip
      DRAFT REJECTION NOTICE (prototype - not an official TTB communication)

      Application serial number: #{application.serial_number}
      Brand name: #{application.brand_name}
      Product type: #{application.beverage_type.capitalize}
      Applicant: #{application.applicant_name_address}
      Date of decision: #{decided ? decided.strftime('%B %-d, %Y') : 'pending'}

      The label submitted with this application cannot be approved as filed.
      The findings below identify each item, the problem observed, and the
      rule it concerns.
    TEXT
  end

  def findings_section(checks)
    flagged = checks.select { |c| %w[fail needs_review].include?(c.verdict) }
                    .sort_by { |c| -c.severity }
    return "FINDINGS\n\nNo individual label findings were cited; see the reviewer note below." if flagged.empty?

    lines = flagged.each_with_index.map do |check, index|
      finding_text(check, index + 1)
    end
    "FINDINGS\n\n#{lines.join("\n\n")}"
  end

  def finding_text(check, number)
    framing = check.verdict == "fail" ? "Does not conform" : "Requires correction or clarification"
    parts = [ "#{number}. #{field_label(check.field)} - #{framing}." ]
    parts << "   On the application: #{check.expected}" if check.expected.present?
    parts << "   On the label: #{check.extracted.presence || 'not found'}"
    parts << "   #{check.note}" if check.note.present?
    parts << "   Reference: #{check.citation}" if check.citation.present?
    parts.join("\n")
  end

  def reviewer_note(verification)
    return nil if verification.decision_note.blank?

    "REVIEWER NOTE\n\n#{verification.decision_note}"
  end

  def footer
    <<~TEXT.strip
      A corrected label may be resubmitted with the same application serial
      number. Each finding above cites the Beverage Alcohol Manual rule or
      regulation it concerns; where the manual and current regulations
      differ, the finding says so.
    TEXT
  end
end
