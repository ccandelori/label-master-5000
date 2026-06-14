# frozen_string_literal: true

class DecisionsController < ApplicationController
  before_action :set_application

  def create
    unless @application.reviewer_visible?
      return respond_with_failure("Decisions are recorded on production-review applications only.")
    end

    verification = @application.verifications.find(params.expect(decision: [ :verification_id ])[:verification_id])
    decision_params = params.expect(decision: [ :verification_id, :decision, :note ])

    verification.record_decision(decision: decision_params[:decision], note: decision_params[:note].presence)
    respond_to do |format|
      format.html { redirect_back_or_to @application, notice: "Decision recorded." }
      format.json { render json: { ok: true, verification_id: verification.id } }
    end
  rescue ArgumentError
    respond_with_failure("Unknown decision.")
  end

  # Undo: clears the decision on a verification, returning the application
  # to the undecided queue. The review-mode toast calls this within its
  # five-second window; the record page offers it any time.
  def destroy
    verification = @application.verifications.find(params.expect(:verification_id))
    verification.undo_decision

    respond_to do |format|
      format.html { redirect_back_or_to @application, notice: "Decision undone." }
      format.json { render json: { ok: true, verification_id: verification.id } }
    end
  end

  private

  def set_application
    @application = LabelApplication.find(params[:label_application_id])
  end

  def respond_with_failure(message)
    respond_to do |format|
      format.html { redirect_back_or_to @application, alert: message }
      format.json { render json: { ok: false, error: message }, status: :unprocessable_entity }
    end
  end
end
