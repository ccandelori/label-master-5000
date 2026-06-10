# frozen_string_literal: true

# The promotion bridge: filing a pre-review sandbox record to TTB
# (simulating a COLAs Online submission). Flips the channel to submitted,
# which removes it from the sandbox and places it in the reviewer queue.
class SubmissionsController < ApplicationController
  def create
    application = LabelApplication.find(params[:label_application_id])

    if application.submitted?
      redirect_to application, alert: "This application has already been submitted to TTB."
    else
      application.submitted!
      redirect_to application, notice: "Submitted to TTB - this application is now in the reviewer queue."
    end
  end
end
