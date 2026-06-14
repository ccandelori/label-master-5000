# frozen_string_literal: true

require "test_helper"

class ArtworkRoleResolverTest < ActiveSupport::TestCase
  Attachment = Data.define(:path, :image_type)

  def attachment(filename, image_type)
    Attachment.new(
      path: "/colasonline/publicViewAttachment.do?filename=#{ERB::Util.url_encode(filename)}&filetype=l",
      image_type: image_type
    )
  end

  test "filename evidence resolves contradictory registry image type text" do
    actual_back = attachment("Screenshot 2023-01-01 203947TTB Back.png", "Brand (front) or keg collar")
    actual_front = attachment("Screenshot 2023-01-01 203830TTB Front.png", "Back")

    front, back = EvalCorpus::ArtworkRoleResolver.pick_front_back([ actual_back, actual_front ])

    assert_equal actual_front, front
    assert_equal actual_back, back
    assert EvalCorpus::ArtworkRoleResolver.role_conflict?(actual_back)
    assert EvalCorpus::ArtworkRoleResolver.role_conflict?(actual_front)
  end

  test "registry role text still works when filenames carry no role" do
    front_image = attachment("label-a.png", "Brand (front) or keg collar")
    back_image = attachment("label-b.png", "Back")

    front, back = EvalCorpus::ArtworkRoleResolver.pick_front_back([ front_image, back_image ])

    assert_equal front_image, front
    assert_equal back_image, back
  end

  test "single raster image becomes front artwork" do
    image = attachment("only-label.png", "Other")

    assert_equal [ image, nil ], EvalCorpus::ArtworkRoleResolver.pick_front_back([ image ])
  end
end
