import { Controller } from "@hotwired/stimulus"

// Review mode: the label front and center on a dark workspace, callouts in
// the margin columns tied to their bounding boxes by elbowed leader lines,
// two-button decisions, and immediate advance through the queue.
//
// Keyboard: A approve, R reject, B request better image, Space skip,
// D open the full record, U undo the last decision (5s window).
export default class extends Controller {
  static targets = [
    "workspace", "stage", "svg", "leftColumn", "rightColumn", "image",
    "caption", "fallback", "empty", "controls", "progress",
    "toast", "toastMessage", "srStatus", "srFindings"
  ]
  static values = { initial: Object, nextUrl: String, exitUrl: String }

  static LINE_COLORS = {
    fail: "#f87171",
    needs_review: "#fbbf24",
    pass_with_note: "#2dd4bf",
    pass: "#4ade80",
    default: "#a8a29e"
  }

  connect() {
    this.current = this.initialValue.application ? this.initialValue : null
    this.next = null
    this.prefetchPromise = null
    this.deferred = []
    this.lastDecided = null
    this.advancing = false
    this.toastTimer = null
    this.reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches

    this.keyHandler = (event) => this.handleKey(event)
    document.addEventListener("keydown", this.keyHandler)

    this.resizeObserver = new ResizeObserver(() => this.layoutCallouts())
    this.resizeObserver.observe(this.imageTarget)
    this.imageTarget.addEventListener("load", () => this.layoutCallouts())

    if (this.current) {
      this.render(this.current)
      this.prefetch()
    } else {
      this.showEmpty()
    }
  }

  disconnect() {
    document.removeEventListener("keydown", this.keyHandler)
    this.resizeObserver.disconnect()
    clearTimeout(this.toastTimer)
  }

  // --- decisions -----------------------------------------------------------

  approve() { this.decide("approve", "Approved") }
  reject() { this.decide("reject", "Rejected") }
  requestRetake() { this.decide("retake_requested", "Better image requested for") }

  decide(kind, verb) {
    if (!this.current || this.advancing) return

    const decided = this.current
    this.lastDecided = decided
    this.showToast(`${verb} ${decided.application.brand_name} —`)
    this.announce(`${verb} ${decided.application.brand_name}.`)

    fetch(decided.decision_path, {
      method: "POST",
      headers: this.jsonHeaders(),
      body: JSON.stringify({ decision: { verification_id: decided.verification.id, decision: kind } })
    }).then((response) => {
      if (!response.ok) throw new Error(`decision failed (${response.status})`)
    }).catch(() => {
      this.lastDecided = null
      this.deferred.unshift(decided)
      this.showToast(`Could not record the decision for ${decided.application.brand_name} — it stays in the queue.`)
    })

    this.advance()
  }

  skip() {
    if (!this.current || this.advancing) return
    this.deferred.push(this.current)
    this.advance()
  }

  undo() {
    if (!this.lastDecided) return
    const restored = this.lastDecided
    this.lastDecided = null
    this.hideToast()

    fetch(restored.decision_path, {
      method: "DELETE",
      headers: this.jsonHeaders(),
      body: JSON.stringify({ verification_id: restored.verification.id })
    }).then((response) => {
      if (!response.ok) throw new Error(`undo failed (${response.status})`)
      if (this.current) this.deferred.unshift(this.current)
      this.current = restored
      this.next = null
      this.transitionTo(() => this.render(restored))
      this.prefetch()
      this.announce(`Decision undone. Back on ${restored.application.brand_name}.`)
    }).catch(() => {
      this.showToast("Could not undo - open the record page to change the decision.")
    })
  }

  openDetails() {
    if (this.current) window.location.assign(this.current.application.show_path)
  }

  handleKey(event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return
    const key = event.key.toLowerCase()
    if (key === "escape") {
      window.location.assign(this.exitUrlValue)
    } else if (key === " ") {
      event.preventDefault()
      this.skip()
    } else if (key === "a") {
      this.approve()
    } else if (key === "r") {
      this.reject()
    } else if (key === "b") {
      this.requestRetake()
    } else if (key === "d") {
      this.openDetails()
    } else if (key === "u") {
      this.undo()
    }
  }

  // --- queue movement ------------------------------------------------------

  async advance() {
    this.advancing = true
    // A fast reviewer can outrun the prefetch; wait for it rather than
    // declaring the queue clear early.
    if (!this.next && this.prefetchPromise) await this.prefetchPromise

    const upcoming = this.takeNext()
    this.current = upcoming
    this.next = null

    this.transitionTo(() => {
      if (upcoming) {
        this.render(upcoming)
      } else {
        this.showEmpty()
      }
      this.advancing = false
    })
    if (upcoming) this.prefetch()
  }

  // Prefer the prefetched server item; fall back to deferred (skipped) ones
  // once the server is dry.
  takeNext() {
    if (this.next && this.next.application) {
      const item = this.next
      // A skipped item may come back from the server; don't show it twice.
      this.deferred = this.deferred.filter((p) => p.application.id !== item.application.id)
      return item
    }
    return this.deferred.shift() || null
  }

  prefetch() {
    const skipIds = [
      this.current?.application.id,
      ...this.deferred.map((p) => p.application.id)
    ].filter(Boolean)

    this.prefetchPromise = fetch(`${this.nextUrlValue}?skip=${skipIds.join(",")}`, { headers: { Accept: "application/json" } })
      .then((response) => response.json())
      .then((payload) => {
        this.next = payload
        if (payload.artwork_url) {
          const img = new Image()
          img.src = payload.artwork_url
        }
      })
      .catch(() => { this.next = null })
  }

  transitionTo(swap) {
    if (this.reducedMotion) {
      swap()
      return
    }
    this.stageTarget.style.opacity = "0"
    setTimeout(() => {
      swap()
      this.stageTarget.style.opacity = "1"
    }, 150)
  }

  // --- rendering -----------------------------------------------------------

  render(payload) {
    this.emptyTarget.classList.add("hidden")
    this.emptyTarget.classList.remove("flex")
    this.stageTarget.classList.remove("hidden")
    this.controlsTarget.classList.remove("invisible")

    const app = payload.application
    this.progressTarget.textContent = `${payload.remaining} in queue`
    this.captionTarget.innerHTML = `
      <p class="text-lg font-semibold">${this.escape(app.brand_name)}</p>
      <p class="text-sm text-stone-400">
        ${this.escape(app.serial_number)} · ${this.escape(app.beverage_type)}
        ${app.alcohol_content ? ` · ${this.escape(app.alcohol_content)}% ABV` : ""}
        · ${this.escape(app.net_contents)}
      </p>`

    if (payload.artwork_url) {
      this.imageTarget.classList.remove("hidden")
      this.imageTarget.alt = `Label artwork for ${app.brand_name}`
      this.imageTarget.src = payload.artwork_url
      if (this.imageTarget.complete) this.layoutCallouts()
    } else {
      this.imageTarget.classList.add("hidden")
      this.clearAnnotations()
    }

    this.renderFallback(payload)
    this.renderScreenReaderMirror(payload)
  }

  // Small screens hide the margin columns; findings drop below the artwork.
  // The same panel carries the retake notice and the no-preview state.
  renderFallback(payload) {
    const columnsHidden = getComputedStyle(this.leftColumnTarget).display === "none"
    const retake = payload.verification.overall_verdict === "request_retake"
    const pieces = []

    if (retake) {
      pieces.push(`<p class="rounded-lg border border-amber-500/50 bg-amber-950/40 text-amber-200 px-4 py-3">
        The artwork could not be read reliably - no field verdicts were issued.
        Request a better image rather than judging from a bad read.</p>`)
    }
    if (!payload.artwork_url) {
      pieces.push(`<p class="text-stone-400 text-center">No artwork preview available.</p>`)
    }
    if ((columnsHidden || !payload.artwork_url) && payload.findings.length) {
      pieces.push(payload.findings.map((f) => `
        <p class="rounded-lg border border-stone-700 bg-stone-900 px-4 py-2.5">
          <span class="font-semibold" style="color: ${this.colorFor(f.verdict)}">${this.escape(f.label)} — ${this.escape(f.verdict_label)}</span>
          ${f.note ? `<span class="block text-stone-300">${this.escape(f.note)}</span>` : ""}
          ${f.citation ? `<span class="block text-stone-500 text-sm">${this.escape(f.citation)}</span>` : ""}
        </p>`).join(""))
    }

    this.fallbackTarget.innerHTML = pieces.join("")
    this.fallbackTarget.classList.toggle("hidden", pieces.length === 0)
    this.fallbackTarget.classList.toggle("space-y-2", pieces.length > 0)
  }

  renderScreenReaderMirror(payload) {
    const s = payload.summary
    this.announce(
      `Now reviewing ${payload.application.brand_name}, serial ${payload.application.serial_number}. ` +
      `${s.fails} failed, ${s.needs_review} need review, ${s.passes} passed. ${payload.remaining} in queue.`
    )
    this.srFindingsTarget.innerHTML = payload.findings.length
      ? `<ul>${payload.findings.map((f) =>
          `<li>${this.escape(f.label)}: ${this.escape(f.verdict_label)}.
           ${this.escape(f.note || "")} ${this.escape(f.citation || "")}</li>`).join("")}</ul>`
      : "<p>No flagged findings.</p>"
  }

  showEmpty() {
    this.stageTarget.classList.add("hidden")
    this.controlsTarget.classList.add("invisible")
    this.emptyTarget.classList.remove("hidden")
    this.emptyTarget.classList.add("flex")
    this.progressTarget.textContent = ""
    this.clearAnnotations()
    this.announce("Queue clear. Every submitted application has a decision.")
  }

  // --- callout layout ------------------------------------------------------

  clearAnnotations() {
    this.svgTarget.replaceChildren()
    this.leftColumnTarget.replaceChildren()
    this.rightColumnTarget.replaceChildren()
  }

  layoutCallouts() {
    this.clearAnnotations()
    if (!this.current || !this.current.artwork_url) return
    if (this.imageTarget.naturalWidth === 0) return
    if (getComputedStyle(this.leftColumnTarget).display === "none") return

    const wsRect = this.workspaceTarget.getBoundingClientRect()
    const imgRect = this.imageTarget.getBoundingClientRect()
    // Bboxes arrive in normalized 0-1000 coordinates (resolution-independent).
    const scaleX = imgRect.width / 1000
    const scaleY = imgRect.height / 1000
    const imgLeft = imgRect.left - wsRect.left
    const imgTop = imgRect.top - wsRect.top

    const boxes = this.current.boxes.filter((b) => b.page === 1)
    const sides = { left: [], right: [] }

    boxes.forEach((box) => {
      const [x, y, w, h] = box.bbox
      const side = x + w / 2 < 500 ? "left" : "right"
      sides[side].push({
        box,
        targetY: imgTop + (y + h / 2) * scaleY,
        edges: {
          left: imgLeft + x * scaleX,
          right: imgLeft + (x + w) * scaleX
        },
        rect: { x: imgLeft + x * scaleX, y: imgTop + y * scaleY, w: w * scaleX, h: h * scaleY }
      })
    })

    const allItems = [ ...sides.left, ...sides.right ]
    this.drawSpotlight(allItems, {
      x: imgLeft, y: imgTop, w: imgRect.width, h: imgRect.height
    })
    this.drawBoxOutlines(allItems)
    this.placeColumn(sides.left, this.leftColumnTarget, "left", wsRect)
    this.placeColumn(sides.right, this.rightColumnTarget, "right", wsRect)
  }

  // Dims the artwork slightly everywhere except inside the bounding boxes,
  // so the annotated regions read as spotlit.
  drawSpotlight(items, image) {
    if (items.length === 0) return

    const svgNS = "http://www.w3.org/2000/svg"
    const defs = document.createElementNS(svgNS, "defs")
    const mask = document.createElementNS(svgNS, "mask")
    mask.setAttribute("id", "bbox-spotlight")

    const visible = document.createElementNS(svgNS, "rect")
    visible.setAttribute("x", image.x)
    visible.setAttribute("y", image.y)
    visible.setAttribute("width", image.w)
    visible.setAttribute("height", image.h)
    visible.setAttribute("fill", "white")
    mask.appendChild(visible)

    items.forEach(({ rect }) => {
      const hole = document.createElementNS(svgNS, "rect")
      hole.setAttribute("x", rect.x)
      hole.setAttribute("y", rect.y)
      hole.setAttribute("width", Math.max(rect.w, 6))
      hole.setAttribute("height", Math.max(rect.h, 6))
      hole.setAttribute("rx", "3")
      hole.setAttribute("fill", "black")
      mask.appendChild(hole)
    })
    defs.appendChild(mask)
    this.svgTarget.appendChild(defs)

    const dim = document.createElementNS(svgNS, "rect")
    dim.setAttribute("x", image.x)
    dim.setAttribute("y", image.y)
    dim.setAttribute("width", image.w)
    dim.setAttribute("height", image.h)
    dim.setAttribute("fill", "black")
    dim.setAttribute("opacity", "0.35")
    dim.setAttribute("mask", "url(#bbox-spotlight)")
    this.svgTarget.appendChild(dim)
  }

  drawBoxOutlines(items) {
    items.forEach(({ box, rect }) => {
      const el = document.createElementNS("http://www.w3.org/2000/svg", "rect")
      el.setAttribute("x", rect.x)
      el.setAttribute("y", rect.y)
      el.setAttribute("width", Math.max(rect.w, 6))
      el.setAttribute("height", Math.max(rect.h, 6))
      el.setAttribute("fill", "none")
      el.setAttribute("stroke", this.colorFor(box.verdict))
      el.setAttribute("stroke-width", "2.5")
      el.setAttribute("rx", "3")
      this.svgTarget.appendChild(el)
    })
  }

  // Greedy vertical slotting: callouts keep their box's vertical order and
  // never overlap; each line elbows from the card to its box edge.
  placeColumn(items, column, side, wsRect) {
    items.sort((a, b) => a.targetY - b.targetY)

    // Callouts hug the artwork side of their column so leader lines stay short.
    const elements = items.map((item) => {
      const el = document.createElement("div")
      el.className = `absolute inset-x-0 flex ${side === "left" ? "justify-end" : "justify-start"}`
      el.innerHTML = this.calloutHtml(item.box)
      el.style.visibility = "hidden"
      column.appendChild(el)
      return el
    })

    let cursor = 0
    const placed = items.map((item, index) => {
      const el = elements[index]
      const height = el.offsetHeight
      const top = Math.max(item.targetY - height / 2, cursor)
      el.style.top = `${top}px`
      el.style.visibility = ""
      cursor = top + height + 10
      return { item, el, top, height }
    })

    // If the stack ran past the workspace, shift it up as one block.
    const overflow = cursor - 10 - this.workspaceTarget.clientHeight
    if (overflow > 0) {
      placed.forEach((p) => {
        p.top = Math.max(p.top - overflow, 0)
        p.el.style.top = `${p.top}px`
      })
    }

    // Lines start at the rendered callout's own edge, not the column's -
    // chips are narrower than the column and would otherwise leave a gap.
    placed.forEach(({ item, el, top, height }, index) => {
      const content = el.firstElementChild
      const contentRect = (content || el).getBoundingClientRect()
      const startX = (side === "left" ? contentRect.right : contentRect.left) - wsRect.left
      const startY = top + height / 2
      const endX = side === "left" ? item.edges.left : item.edges.right
      const endY = item.targetY
      this.drawLeaderLine(startX, startY, endX, endY, this.colorFor(item.box.verdict), index)
    })
  }

  drawLeaderLine(startX, startY, endX, endY, color, index) {
    // Stagger the elbow per callout so same-side lines don't share one
    // vertical channel.
    const fraction = 0.3 + 0.12 * (index % 5)
    const midX = startX + (endX - startX) * fraction
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path")
    path.setAttribute("d", `M ${startX} ${startY} L ${midX} ${startY} L ${midX} ${endY} L ${endX} ${endY}`)
    path.setAttribute("fill", "none")
    path.setAttribute("stroke", color)
    path.setAttribute("stroke-width", "2")
    path.setAttribute("opacity", "0.9")
    this.svgTarget.appendChild(path)

    const dot = document.createElementNS("http://www.w3.org/2000/svg", "circle")
    dot.setAttribute("cx", endX)
    dot.setAttribute("cy", endY)
    dot.setAttribute("r", "3")
    dot.setAttribute("fill", color)
    this.svgTarget.appendChild(dot)
  }

  calloutHtml(box) {
    const color = this.colorFor(box.verdict)
    if (box.verdict === "fail" || box.verdict === "needs_review") {
      return `
        <div class="rounded-lg border bg-stone-900/90 px-3 py-2" style="border-color: ${color}">
          <p class="font-semibold text-sm" style="color: ${color}">${this.escape(box.label)} — ${this.escape(box.verdict_label)}</p>
          ${box.note ? `<p class="text-sm text-stone-300 mt-0.5">${this.escape(box.note)}</p>` : ""}
          ${box.citation ? `<p class="text-xs text-stone-500 mt-0.5">${this.escape(box.citation)}</p>` : ""}
        </div>`
    }
    return `
      <p class="inline-flex items-center gap-1.5 rounded-full border border-stone-700 bg-stone-900/90 px-2.5 py-1 text-sm text-stone-300">
        <span style="color: ${color}" aria-hidden="true">✓</span> ${this.escape(box.label)}
      </p>`
  }

  colorFor(verdict) {
    return this.constructor.LINE_COLORS[verdict] || this.constructor.LINE_COLORS.default
  }

  // --- toast and announcements ---------------------------------------------

  showToast(message) {
    clearTimeout(this.toastTimer)
    this.toastMessageTarget.textContent = message
    this.toastTarget.classList.remove("hidden")
    this.toastTimer = setTimeout(() => {
      this.hideToast()
      this.lastDecided = null
    }, 5000)
  }

  hideToast() {
    clearTimeout(this.toastTimer)
    this.toastTarget.classList.add("hidden")
  }

  announce(message) {
    this.srStatusTarget.textContent = message
  }

  jsonHeaders() {
    return {
      "Content-Type": "application/json",
      Accept: "application/json",
      "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
    }
  }

  escape(text) {
    const div = document.createElement("div")
    div.textContent = String(text ?? "")
    return div.innerHTML
  }
}
