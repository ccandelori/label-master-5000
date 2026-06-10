# frozen_string_literal: true

class DecisionsController < ApplicationController
  def create
    application = LabelApplication.find(params[:label_application_id])

    if application.pre_review?
      return redirect_to application,
                         alert: "Decisions are recorded on submitted applications only - this one is still in pre-review."
    end

    verification = application.verifications.find(params.expect(decision: [ :verification_id ])[:verification_id])
    decision_params = params.expect(decision: [ :verification_id, :decision, :note ])

    verification.record_decision(decision: decision_params[:decision], note: decision_params[:note].presence)
    redirect_to application, notice: "Decision recorded."
  rescue ArgumentError
    redirect_to application, alert: "Unknown decision."
  end
end
