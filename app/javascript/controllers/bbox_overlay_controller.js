import { Controller } from "@hotwired/stimulus"

// Draws verdict-colored outlines over the label artwork at the pixel
// coordinates the extractor reported, scaled to the displayed image size.
// Hovering a results-table row highlights its outline; clicking an outline
// opens an annotation with the verdict, reason, and citation.
export default class extends Controller {
  static targets = ["image", "frame"]
  static values = { boxes: Array }

  connect() {
    this.popover = null
    // The popover frequently covers its own box, so re-clicking the box is
    // not a workable dismissal; any click outside the popover (or Escape)
    // closes it. Box clicks stop propagation, so toggling still works.
    this.outsideClickHandler = (event) => {
      if (this.popover && !this.popover.contains(event.target)) this.closePopover()
    }
    this.escapeHandler = (event) => {
      if (event.key === "Escape") this.closePopover()
    }
    document.addEventListener("click", this.outsideClickHandler)
    document.addEventListener("keydown", this.escapeHandler)

    if (this.hasImageTarget) {
      if (this.imageTarget.complete) {
        this.render()
      } else {
        this.imageTarget.addEventListener("load", () => this.render(), { once: true })
      }
      this.resizeObserver = new ResizeObserver(() => this.render())
      this.resizeObserver.observe(this.imageTarget)
    }
  }

  disconnect() {
    if (this.resizeObserver) this.resizeObserver.disconnect()
    document.removeEventListener("click", this.outsideClickHandler)
    document.removeEventListener("keydown", this.escapeHandler)
  }

  render() {
    if (!this.hasFrameTarget || this.imageTarget.naturalWidth === 0) return

    this.frameTarget.querySelectorAll("[data-bbox-box]").forEach((el) => el.remove())
    this.closePopover()

    this.boxesValue.filter((box) => box.page === 1).forEach((box) => {
      // Each box carries the pixel basis the extractor measured against.
      const [basisW, basisH] = box.basis || [1000, 1000]
      const scaleX = this.imageTarget.clientWidth / basisW
      const scaleY = this.imageTarget.clientHeight / basisH
      const [x, y, w, h] = box.bbox
      const el = document.createElement("button")
      el.type = "button"
      el.dataset.bboxBox = box.field
      el.setAttribute("aria-label", `${box.label}: ${box.verdict_label}. Activate for details.`)
      el.className = "absolute rounded-sm border-2 border-dashed cursor-pointer " + this.colorFor(box.verdict)
      el.style.left = `${x * scaleX}px`
      el.style.top = `${y * scaleY}px`
      el.style.width = `${Math.max(w * scaleX, 8)}px`
      el.style.height = `${Math.max(h * scaleY, 8)}px`
      el.style.backgroundColor = "transparent"
      el.addEventListener("click", (event) => {
        event.stopPropagation()
        this.togglePopover(el, box)
      })
      this.frameTarget.appendChild(el)
    })
  }

  colorFor(verdict) {
    if (verdict === "fail") return "border-fail hover:bg-fail/15"
    if (verdict === "needs_review") return "border-warn hover:bg-warn/15"
    if (verdict === "pass_with_note") return "border-pass hover:bg-pass/15"
    if (verdict === "not_required" || verdict === "not_applicable") return "border-line-strong hover:bg-ink/10"
    return "border-pass hover:bg-pass/15"
  }

  // Hover linking from the results table (rows carry data-field).
  highlight(event) {
    this.setEmphasis(event.currentTarget.dataset.field, true)
  }

  unhighlight(event) {
    this.setEmphasis(event.currentTarget.dataset.field, false)
  }

  setEmphasis(field, on) {
    this.frameTarget?.querySelectorAll("[data-bbox-box]").forEach((el) => {
      const box = this.boxesValue.find((b) => b.field === el.dataset.bboxBox)
      const related = box && (box.field === field || (box.related_fields || []).includes(field))
      el.style.borderStyle = related && on ? "solid" : "dashed"
      el.style.borderWidth = related && on ? "3px" : "2px"
    })
  }

  togglePopover(anchor, box) {
    if (this.popover && this.popover.dataset.field === box.field) {
      this.closePopover()
      return
    }
    this.closePopover()

    const pop = document.createElement("div")
    pop.dataset.field = box.field
    pop.setAttribute("role", "dialog")
    pop.className = "absolute z-10 max-w-72 rounded-lg border border-line-strong bg-raised p-3 text-sm shadow-lg"
    pop.innerHTML = `
      <p class="font-semibold">${this.escape(box.label)} — ${this.escape(box.verdict_label)}</p>
      ${box.note ? `<p class="mt-1 text-ink-muted">${this.escape(box.note)}</p>` : ""}
      ${box.citation ? `<p class="mt-1 text-ink-faint">${this.escape(box.citation)}</p>` : ""}
    `

    const frameRect = this.frameTarget.getBoundingClientRect()
    const anchorRect = anchor.getBoundingClientRect()
    const top = anchorRect.bottom - frameRect.top + 6
    pop.style.left = `${Math.max(anchorRect.left - frameRect.left, 0)}px`
    pop.style.top = `${top}px`

    this.frameTarget.appendChild(pop)
    this.popover = pop

    // Flip above the box when it would overflow the frame.
    if (top + pop.offsetHeight > this.frameTarget.offsetHeight) {
      pop.style.top = `${Math.max(anchorRect.top - frameRect.top - pop.offsetHeight - 6, 0)}px`
    }
  }

  closePopover() {
    if (this.popover) {
      this.popover.remove()
      this.popover = null
    }
  }

  escape(text) {
    const div = document.createElement("div")
    div.textContent = String(text)
    return div.innerHTML
  }
}
