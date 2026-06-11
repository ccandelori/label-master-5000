# frozen_string_literal: true

namespace :ocr do
  desc "Explain a field's text and box: bin/rails 'ocr:explain[SERIAL,fanciful_name]'"
  task :explain, [ :serial, :field ] => :environment do |_t, args|
    application = LabelApplication.find_by(serial_number: args[:serial])
    abort "no application with serial #{args[:serial].inspect}" if application.nil?

    puts Extraction::Diagnostics.explain(application: application, field: args[:field] || "fanciful_name")
  end
end
