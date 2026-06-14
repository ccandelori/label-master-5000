import { Controller } from "@hotwired/stimulus"

// Applies a spotlight mask over the label artwork at the pixel coordinates
// the extractor reported, scaled to the displayed image size. Hovering a
// finding row reveals only that region; the text itself stays unobscured.
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

    this.resizeObserver = new ResizeObserver(() => this.render())
    this.imageTargets.forEach((image) => {
      if (image.complete) {
        this.render()
      } else {
        image.addEventListener("load", () => this.render(), { once: true })
      }
      this.resizeObserver.observe(image)
    })
  }

  disconnect() {
    if (this.resizeObserver) this.resizeObserver.disconnect()
    document.removeEventListener("click", this.outsideClickHandler)
    document.removeEventListener("keydown", this.escapeHandler)
  }

  // One frame per artwork page (front and optional back), each carrying
  // its page in data-page; every box renders on the frame of its page.
  render() {
    this.closePopover()
    this.frameTargets.forEach((frame, index) => this.renderFrame(frame, this.imageTargets[index]))
  }

  renderFrame(frame, image) {
    if (!image || image.naturalWidth === 0) return

    frame.querySelectorAll("[data-bbox-generated]").forEach((el) => el.remove())
    const page = Number(frame.dataset.page || 1)
    const width = image.clientWidth
    const height = image.clientHeight
    if (width === 0 || height === 0) return

    const svgNS = "http://www.w3.org/2000/svg"
    const svg = document.createElementNS(svgNS, "svg")
    svg.dataset.bboxGenerated = "overlay"
    svg.setAttribute("class", "absolute inset-0 w-full h-full pointer-events-none")
    svg.setAttribute("aria-hidden", "true")
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`)
    frame.appendChild(svg)

    const maskId = `bbox-spotlight-${page}-${Math.floor(Math.random() * 1000000)}`
    const defs = document.createElementNS(svgNS, "defs")
    const mask = document.createElementNS(svgNS, "mask")
    mask.setAttribute("id", maskId)
    const visible = document.createElementNS(svgNS, "rect")
    visible.setAttribute("x", 0)
    visible.setAttribute("y", 0)
    visible.setAttribute("width", width)
    visible.setAttribute("height", height)
    visible.setAttribute("fill", "white")
    mask.appendChild(visible)

    const hole = document.createElementNS(svgNS, "rect")
    hole.setAttribute("rx", "3")
    hole.setAttribute("fill", "black")
    mask.appendChild(hole)
    defs.appendChild(mask)
    svg.appendChild(defs)

    const dim = document.createElementNS(svgNS, "rect")
    dim.setAttribute("x", 0)
    dim.setAttribute("y", 0)
    dim.setAttribute("width", width)
    dim.setAttribute("height", height)
    dim.setAttribute("class", "rv-dim")
    dim.setAttribute("mask", `url(#${maskId})`)
    dim.dataset.active = false
    svg.appendChild(dim)

    frame._bboxSpotlight = { dim, hole }

    this.boxesValue.filter((box) => box.page === page).forEach((box) => {
      // Each box carries the pixel basis the extractor measured against.
      const [basisW, basisH] = box.basis || [1000, 1000]
      const scaleX = width / basisW
      const scaleY = height / basisH
      const [x, y, w, h] = box.bbox
      const el = document.createElement("button")
      el.type = "button"
      el.dataset.bboxBox = box.field
      el.dataset.bboxGenerated = "hit-target"
      el.setAttribute("aria-label", `${box.label}: ${box.verdict_label}.${box.approximate ? " Location approximate." : ""} Activate for details.`)
      el.className = "absolute rounded-sm cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
      el.style.left = `${x * scaleX}px`
      el.style.top = `${y * scaleY}px`
      el.style.width = `${Math.max(w * scaleX, 8)}px`
      el.style.height = `${Math.max(h * scaleY, 8)}px`
      el.style.backgroundColor = "transparent"
      el.style.border = "0"
      el.style.padding = "0"
      el._bboxRect = { x: x * scaleX, y: y * scaleY, w: Math.max(w * scaleX, 8), h: Math.max(h * scaleY, 8) }
      el.addEventListener("mouseenter", () => this.spotlight(frame, el._bboxRect))
      el.addEventListener("mouseleave", () => this.clearSpotlights())
      el.addEventListener("click", (event) => {
        event.stopPropagation()
        this.togglePopover(el, box, frame)
      })
      frame.appendChild(el)
    })
  }

  // Hover linking from the results table (rows carry data-field).
  highlight(event) {
    this.setEmphasis(event.currentTarget.dataset.field, true)
  }

  unhighlight(event) {
    this.setEmphasis(event.currentTarget.dataset.field, false)
  }

  setEmphasis(field, on) {
    this.clearSpotlights()
    if (!on) return

    const target = this.frameTargets.flatMap((frame) =>
      Array.from(frame.querySelectorAll("[data-bbox-box]")).map((el) => [frame, el])
    ).find(([, el]) => {
      const box = this.boxesValue.find((b) => b.field === el.dataset.bboxBox)
      return box && (box.field === field || (box.related_fields || []).includes(field))
    })

    if (target) this.spotlight(target[0], target[1]._bboxRect)
  }

  spotlight(frame, rect) {
    const spotlight = frame._bboxSpotlight
    if (!spotlight || !rect) return

    spotlight.hole.setAttribute("x", rect.x)
    spotlight.hole.setAttribute("y", rect.y)
    spotlight.hole.setAttribute("width", rect.w)
    spotlight.hole.setAttribute("height", rect.h)
    spotlight.dim.dataset.active = true
  }

  clearSpotlights() {
    this.frameTargets.forEach((frame) => {
      if (frame._bboxSpotlight) frame._bboxSpotlight.dim.dataset.active = false
    })
  }

  togglePopover(anchor, box, frame) {
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

    const frameRect = frame.getBoundingClientRect()
    const anchorRect = anchor.getBoundingClientRect()
    const top = anchorRect.bottom - frameRect.top + 6
    pop.style.left = `${Math.max(anchorRect.left - frameRect.left, 0)}px`
    pop.style.top = `${top}px`

    frame.appendChild(pop)
    this.popover = pop

    // Flip above the box when it would overflow the frame.
    if (top + pop.offsetHeight > frame.offsetHeight) {
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
