# frozen_string_literal: true

# Bulk promotion bridge: files every pre-review record in a batch to TTB
# at once, mirroring how a manufacturer pre-checks a product line and then
# submits the lot.
class BatchSubmissionsController < ApplicationController
  def create
    batch = Batch.find(params[:batch_id])
    count = batch.label_applications.pre_review.update_all(channel: "submitted", updated_at: Time.current)

    if count.positive?
      redirect_to batch, notice: "Submitted #{count} #{'application'.pluralize(count)} to TTB."
    else
      redirect_to batch, alert: "Every application in this batch has already been submitted."
    end
  end
end
