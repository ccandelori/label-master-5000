# frozen_string_literal: true

class RefineVerificationJob < ApplicationJob
  queue_as :verification

  def perform(verification_id, provider, model)
    verification = Verification.find(verification_id)
    VerifierV2.refine_verification(verification: verification, provider: provider, model: model)
  end
end
