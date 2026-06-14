# frozen_string_literal: true

# Bulk promotion bridge: files every validation record in a batch to TTB
# at once, mirroring how a manufacturer validates a product line and then
# submits the lot.
class BatchSubmissionsController < ApplicationController
  def create
    batch = Batch.find(params[:batch_id])
    count = batch.submit_to_ttb

    if count.positive?
      redirect_to batch, notice: "Submitted #{count} #{'application'.pluralize(count)} to TTB."
    else
      redirect_to batch, alert: "Every application in this batch has already been submitted."
    end
  end
end
