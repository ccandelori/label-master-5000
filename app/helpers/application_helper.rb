module ApplicationHelper
  def nav_link(label, path, area:)
    active = current_area == area
    link_to label, path,
            class: "px-4 py-2 rounded-lg hover:bg-panel #{'bg-panel font-medium' if active}",
            aria: { current: active ? "page" : nil }
  end
end
