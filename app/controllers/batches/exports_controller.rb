# frozen_string_literal: true

module Batches
  class ExportsController < ApplicationController
    before_action { @area = :pre_review }

    def show
      batch = Batch.find(params[:batch_id])
      send_data batch.results_csv, filename: "#{batch.name.parameterize}-results.csv", type: "text/csv"
    end
  end
end
