# frozen_string_literal: true

# The promotion bridge: filing a validation workspace record to TTB
# (simulating a COLAs Online submission). Flips the channel to submitted,
# which makes it eligible for filing decisions while preserving history.
class SubmissionsController < ApplicationController
  def create
    application = LabelApplication.find(params[:label_application_id])

    if application.submit_to_ttb
      redirect_to application, notice: "Submitted to TTB. This application remains available in History."
    else
      redirect_to application, alert: "This application has already been submitted to TTB."
    end
  end
end
