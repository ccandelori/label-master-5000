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
  }

  render() {
    if (!this.hasFrameTarget || this.imageTarget.naturalWidth === 0) return

    this.frameTarget.querySelectorAll("[data-bbox-box]").forEach((el) => el.remove())
    this.closePopover()

    const scaleX = this.imageTarget.clientWidth / this.imageTarget.naturalWidth
    const scaleY = this.imageTarget.clientHeight / this.imageTarget.naturalHeight

    this.boxesValue.filter((box) => box.page === 1).forEach((box) => {
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
    if (verdict === "fail") return "border-red-600 hover:bg-red-500/20"
    if (verdict === "needs_review") return "border-amber-500 hover:bg-amber-400/20"
    if (verdict === "pass_with_note") return "border-teal-600 hover:bg-teal-500/20"
    if (verdict === "not_required" || verdict === "not_applicable") return "border-stone-400 hover:bg-stone-400/20"
    return "border-green-600 hover:bg-green-500/20"
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
    pop.className = "absolute z-10 max-w-72 rounded-lg border border-stone-300 bg-white p-3 text-sm shadow-lg"
    pop.innerHTML = `
      <p class="font-semibold">${this.escape(box.label)} — ${this.escape(box.verdict_label)}</p>
      ${box.note ? `<p class="mt-1 text-stone-700">${this.escape(box.note)}</p>` : ""}
      ${box.citation ? `<p class="mt-1 text-stone-500">${this.escape(box.citation)}</p>` : ""}
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
