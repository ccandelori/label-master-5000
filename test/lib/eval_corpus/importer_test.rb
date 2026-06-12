# frozen_string_literal: true

require "test_helper"

class ImporterTest < ActiveSupport::TestCase
  # Serves the fixture form page for any id; attachment behavior is
  # injectable per test (bytes or a raised FetchError).
  class StubClient
    def initialize(attachment: "fake-jpeg-bytes")
      @attachment = attachment
    end

    def form_html(_ttb_id)
      File.read(Rails.root.join("test/fixtures/files/ttb_form_sample.html"))
    end

    def detail_html(_ttb_id)
      File.read(Rails.root.join("test/fixtures/files/ttb_detail_sample.html"))
    end

    def attachment(_ttb_id, _path)
      raise @attachment if @attachment.is_a?(StandardError)

      @attachment
    end
  end

  def import(client:, ids:)
    file = Tempfile.create("eval-ids")
    file.write(ids.join("\n"))
    file.close
    io = StringIO.new
    EvalCorpus::Importer.new(client: client, io: io).import(count: ids.size, ids_file: file.path)
    io.string
  end

  test "attachment request paths percent-encode raw filenames" do
    path = "/colasonline/publicViewAttachment.do?filename=CE VALLEE LOIRE.png&filetype=l"

    assert_equal "publicViewAttachment.do?filename=CE%20VALLEE%20LOIRE.png&filetype=l",
                 EvalCorpus::RegistryClient.attachment_request_path(path)
  end

  test "a failed image fetch persists nothing" do
    error = EvalCorpus::RegistryClient::FetchError.new("boom")
    output = import(client: StubClient.new(attachment: error), ids: [ "99023001000077" ])

    assert_match(/fetch failed/, output)
    assert_nil LabelApplication.find_by(serial_number: "99023001000077")
  end

  test "an artwork-less eval record is repaired in place" do
    batch = Batch.create!(name: "TTB registry eval 2099-01-01")
    bare = batch.label_applications.create!(
      serial_number: "99023001000088", channel: "submitted", brand_name: "PARADOX BREWERY",
      beverage_type: "malt", applicant_name_address: "Paradox Brewery LLC, North Hudson NY",
      net_contents: EvalCorpus::RegistryRecord::NET_CONTENTS_SENTINEL
    )

    output = import(client: StubClient.new, ids: [ bare.serial_number ])

    assert_match(/repaired "PARADOX BREWERY"/, output)
    assert bare.reload.artwork.attached?
    assert_equal "PARADOX BREWERY", bare.brand_name, "metadata is kept"
    assert_equal batch, bare.batch, "record stays in its original batch"
  end

  test "a complete record is skipped untouched" do
    batch = Batch.create!(name: "TTB registry eval 2099-01-01")
    done = batch.label_applications.new(
      serial_number: "99023001000099", channel: "submitted", brand_name: "DONE",
      beverage_type: "malt", applicant_name_address: "Done Co, Town NY",
      net_contents: "12 fl oz"
    )
    done.artwork.attach(io: StringIO.new("existing-bytes"), filename: "done.jpg", content_type: "image/jpeg")
    done.save!
    checksum = done.artwork.blob.checksum

    output = import(client: StubClient.new, ids: [ done.serial_number ])

    assert_match(/already imported, skipping/, output)
    assert_equal checksum, done.reload.artwork.blob.checksum
  end
end
