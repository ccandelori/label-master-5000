# frozen_string_literal: true

# Enqueues a verification run for an application - the queue's "Run check"
# action for records that have never been checked or whose last check
# errored, and the pre-review record page's "Re-check" (optionally under
# a chosen demo model).
class ChecksController < ApplicationController
  def create
    application = LabelApplication.find(params[:label_application_id])
    provider, model = demo_model_override(application)
    VerifyLabelJob.perform_later(application.id, provider, model)
    notice = "Check queued for #{application.brand_name}#{" under #{model}" if model}."
    redirect_back_or_to application, notice: notice
  end
end
