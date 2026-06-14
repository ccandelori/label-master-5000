# frozen_string_literal: true

# Enqueues a verification run for an application: the history "Run validation"
# action for records that have never been checked or whose last check errored,
# and the validation record page's "Revalidate" action.
class ChecksController < ApplicationController
  def create
    application = LabelApplication.find(params[:label_application_id])
    selection = validation_mode_selection(application)
    application.verify_later(provider: selection.provider, model: selection.model, mode: selection.mode)
    notice = "Validation queued for #{application.brand_name}#{" under #{selection.model}" if selection.model}."
    redirect_back_or_to application, notice: notice
  end
end
