# frozen_string_literal: true

class RuntimeDependenciesController < ActionController::API
  def show
    report = Extraction::RuntimeDependencies.build.report
    ocr_ready = Extraction::RuntimeDependencies.check_ocr_ready
    report = report.merge(ok: report[:ok] && ocr_ready.ok?, ocr_ready: ocr_ready.to_h)
    render json: report, status: report[:ok] ? :ok : :service_unavailable
  end
end
