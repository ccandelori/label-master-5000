module ApplicationHelper
  # Small colored chip identifying which of the three site areas a page
  # belongs to (Reviewer / Pre-review / Rules reference).
  def area_tag(area)
    config = ApplicationController::AREAS[area]
    return if config.nil?

    tag.span(config[:label], class: "inline-block rounded-full px-2.5 py-0.5 text-sm font-medium #{config[:classes]}")
  end

  def nav_link(label, path, area:)
    active = current_area == area
    link_to label, path,
            class: "px-4 py-2 rounded-lg hover:bg-panel #{'bg-panel font-medium' if active}",
            aria: { current: active ? "page" : nil }
  end
end
