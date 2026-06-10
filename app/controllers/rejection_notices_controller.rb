# frozen_string_literal: true

class RejectionNoticesController < ApplicationController
  def show
    application = LabelApplication.find(params[:label_application_id])
    verification = application.verifications.where.not(rejection_notice: nil).order(created_at: :desc).first

    if verification.nil?
      return redirect_to application, alert: "This application has no rejection notice."
    end

    send_data verification.rejection_notice,
              filename: "rejection-notice-#{application.serial_number.parameterize}.txt",
              type: "text/plain",
              disposition: params[:download] ? "attachment" : "inline"
  end
end
