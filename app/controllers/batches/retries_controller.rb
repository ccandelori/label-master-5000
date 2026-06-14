# frozen_string_literal: true

module Batches
  class RetriesController < ApplicationController
    before_action { @area = :pre_review }

    def create
      batch = Batch.find(params[:batch_id])
      readiness = Extraction::RuntimeDependencies.check_ocr_ready
      return redirect_to batch, alert: readiness.error_message unless readiness.ok?

      retried = batch.retry_failed_verifications_later(
        provider: nil,
        model: nil,
        mode: VerifyLabelJob::VERIFIER_V2_MODE
      )
      redirect_to batch, notice: "Re-queued #{retried} #{'row'.pluralize(retried)}."
    end
  end
end
