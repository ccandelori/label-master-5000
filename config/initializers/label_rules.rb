# frozen_string_literal: true

# Fail fast at boot if the BAM rule data is malformed. A typo in rule data
# must never surface as a silently wrong verdict at verification time.
Rails.application.config.after_initialize do
  Rules::Data.all
end
