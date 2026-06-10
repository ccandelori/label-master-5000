# frozen_string_literal: true

# Enqueues a verification run for an application - the queue's "Run check"
# action for records that have never been checked or whose last check errored.
class ChecksController < ApplicationController
  def create
    application = LabelApplication.find(params[:label_application_id])
    VerifyLabelJob.perform_later(application.id)
    redirect_back_or_to application, notice: "Check queued for #{application.brand_name}."
  end
end
