# frozen_string_literal: true

class SampleValidationsController < ApplicationController
  before_action { @area = :pre_review }

  def create
    sample = LabelApplication.validation_samples.find(params.expect(:sample_id))
    validation = sample.build_validation_copy
    validation.save!
    selection = validation_mode_selection(validation)
    validation.verify_later(provider: selection.provider, model: selection.model, mode: selection.mode)

    redirect_to validation, notice: "Sample validation started."
  end
end
