import { Controller } from "@hotwired/stimulus"

// Review mode: the label front and center, every check in the evidence
// inspector at right, grouped by severity with absences badged inline.
// Hovering a row spotlights its box on the artwork (and vice versa);
// clicking unfolds the application-vs-label comparison with its citation.
//
// Keyboard: A approve, R reject, B request better image, Space skip,
// U undo the last decision (5s window), Esc exit.
export default class extends Controller {
  static targets = [
    "workspace", "stage", "frame", "svg", "image", "caption", "fallback",
    "inspector", "empty", "controls", "progress", "summary",
    "toast", "toastMessage", "srStatus", "srFindings"
  ]
  static values = { initial: Object, nextUrl: String, exitUrl: String }

  // SVG strokes resolve through the token layer so both schemes hold.
  static VERDICT_COLORS = {
    fail: "var(--rv-fail)",
    needs_review: "var(--rv-warn)",
    pass_with_note: "var(--rv-pass)",
    pass: "var(--rv-pass)",
    default: "var(--rv-ink-faint)"
  }

  static GROUPS = [
    { key: "fail", title: "Failed", verdicts: [ "fail" ] },
    { key: "needs_review", title: "Needs review", verdicts: [ "needs_review" ] },
    { key: "pass", title: "Passed", verdicts: [ "pass", "pass_with_note" ] }
  ]

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

    this.resizeObserver = new ResizeObserver(() => this.layoutOverlay())
    this.resizeObserver.observe(this.imageTarget)
    this.imageTarget.addEventListener("load", () => this.layoutOverlay())

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
    clearTimeout(this.approveArmTimer)
  }

  // --- decisions -----------------------------------------------------------

  // Approving over failed checks takes a second press: the inspector makes
  // fails visible, this makes them deliberate.
  approve() {
    if (!this.current || this.advancing) return
    const fails = this.current.summary?.fails || 0
    if (fails > 0 && !this.approveArmed) {
      this.approveArmed = true
      clearTimeout(this.approveArmTimer)
      this.approveArmTimer = setTimeout(() => {
        this.approveArmed = false
        this.summaryTarget.textContent = ""
      }, 4000)
      const message = `${fails} ${fails === 1 ? "check" : "checks"} failed — press Approve again to confirm`
      this.summaryTarget.innerHTML = `<span class="font-medium" style="color: var(--rv-fail)">${this.escape(message)}</span>`
      this.announce(message)
      return
    }
    this.approveArmed = false
    clearTimeout(this.approveArmTimer)
    this.decide("approve", "Approved")
  }

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

  handleKey(event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return
    if (event.target.closest("input, textarea, select")) return
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
    this.approveArmed = false
    clearTimeout(this.approveArmTimer)
    this.summaryTarget.textContent = ""

    this.emptyTarget.classList.add("hidden")
    this.emptyTarget.classList.remove("flex")
    this.stageTarget.classList.remove("hidden")
    this.inspectorTarget.classList.remove("lg:hidden")
    this.controlsTarget.classList.remove("invisible")

    const app = payload.application
    this.progressTarget.textContent = `${payload.remaining} in queue`
    this.captionTarget.innerHTML = `
      <p class="text-lg font-semibold tracking-tight">${this.escape(app.brand_name)}</p>
      <p class="text-sm text-ink-muted">
        ${this.escape(app.serial_number)} · ${this.escape(app.beverage_type)}
        ${app.alcohol_content ? ` · ${this.escape(app.alcohol_content)}% ABV` : ""}
        · ${this.escape(app.net_contents)}
      </p>`

    if (payload.artwork_url) {
      this.imageTarget.classList.remove("hidden")
      this.imageTarget.alt = `Label artwork for ${app.brand_name}`
      this.imageTarget.src = payload.artwork_url
      if (this.imageTarget.complete) this.layoutOverlay()
    } else {
      this.imageTarget.classList.add("hidden")
      this.svgTarget.replaceChildren()
    }

    this.renderInspector(payload)
    this.renderFallback(payload)
    this.renderScreenReaderMirror(payload)
  }

  flagged(payload) {
    return (payload.findings || []).filter((f) => f.verdict === "fail" || f.verdict === "needs_review")
  }

  // Small screens hide the inspector; flagged findings drop below the
  // artwork. The same panel carries the retake notice and the no-preview
  // state.
  renderFallback(payload) {
    const inspectorHidden = getComputedStyle(this.inspectorTarget).display === "none"
    const retake = payload.verification.overall_verdict === "request_retake"
    const flagged = this.flagged(payload)
    const pieces = []

    if (retake) {
      pieces.push(`<p class="rounded-lg border border-warn bg-warn-tint text-ink px-4 py-3">
        The artwork could not be read reliably - no field verdicts were issued.
        Request a better image rather than judging from a bad read.</p>`)
    }
    if (!payload.artwork_url) {
      pieces.push(`<p class="text-ink-muted text-center">No artwork preview available.</p>`)
    }
    if ((inspectorHidden || !payload.artwork_url) && flagged.length) {
      pieces.push(flagged.map((f) => `
        <p class="rounded-lg border border-line bg-raised px-4 py-2.5">
          <span class="font-semibold" style="color: ${this.colorFor(f.verdict)}">${this.escape(f.label)} — ${this.escape(f.verdict_label)}</span>
          ${f.note ? `<span class="block text-ink-muted">${this.escape(f.note)}</span>` : ""}
          ${f.citation ? `<span class="block text-ink-faint text-sm">${this.escape(f.citation)}</span>` : ""}
        </p>`).join(""))
    }

    this.fallbackTarget.innerHTML = pieces.join("")
    this.fallbackTarget.classList.toggle("hidden", pieces.length === 0)
    this.fallbackTarget.classList.toggle("space-y-2", pieces.length > 0)
  }

  renderScreenReaderMirror(payload) {
    const s = payload.summary
    const flagged = this.flagged(payload)
    this.announce(
      `Now reviewing ${payload.application.brand_name}, serial ${payload.application.serial_number}. ` +
      `${s.fails} failed, ${s.needs_review} need review, ${s.passes} passed. ${payload.remaining} in queue.`
    )
    this.srFindingsTarget.innerHTML = flagged.length
      ? `<ul>${flagged.map((f) =>
          `<li>${this.escape(f.label)}: ${this.escape(f.verdict_label)}.
           ${this.escape(f.note || "")} ${this.escape(f.citation || "")}</li>`).join("")}</ul>`
      : "<p>No flagged findings.</p>"
  }

  showEmpty() {
    this.stageTarget.classList.add("hidden")
    this.inspectorTarget.classList.add("lg:hidden")
    this.controlsTarget.classList.add("invisible")
    this.emptyTarget.classList.remove("hidden")
    this.emptyTarget.classList.add("flex")
    this.progressTarget.textContent = ""
    this.summaryTarget.textContent = ""
    this.svgTarget.replaceChildren()
    this.announce("Queue clear. Every submitted application has a decision.")
  }

  // --- artwork overlay -----------------------------------------------------

  // The SVG sits inside the artwork frame, so geometry is a pure scale of
  // each box's basis to the rendered image; no workspace offsets.
  layoutOverlay() {
    this.svgTarget.replaceChildren()
    if (!this.current || !this.current.artwork_url) return
    if (this.imageTarget.naturalWidth === 0) return

    const width = this.imageTarget.clientWidth
    const height = this.imageTarget.clientHeight
    if (width === 0) return
    this.svgTarget.setAttribute("viewBox", `0 0 ${width} ${height}`)

    const svgNS = "http://www.w3.org/2000/svg"
    const boxes = (this.current.boxes || []).filter((b) => b.page === 1)

    // Dim everything outside the located regions so they read as spotlit.
    if (boxes.length > 0) {
      const defs = document.createElementNS(svgNS, "defs")
      const mask = document.createElementNS(svgNS, "mask")
      mask.setAttribute("id", "rv-spotlight")
      const visible = document.createElementNS(svgNS, "rect")
      visible.setAttribute("x", 0)
      visible.setAttribute("y", 0)
      visible.setAttribute("width", width)
      visible.setAttribute("height", height)
      visible.setAttribute("fill", "white")
      mask.appendChild(visible)

      boxes.forEach((box) => {
        const rect = this.scaledRect(box, width, height)
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
      dim.setAttribute("x", 0)
      dim.setAttribute("y", 0)
      dim.setAttribute("width", width)
      dim.setAttribute("height", height)
      dim.setAttribute("class", "rv-dim")
      dim.setAttribute("mask", "url(#rv-spotlight)")
      this.svgTarget.appendChild(dim)
    }

    boxes.forEach((box) => {
      const rect = this.scaledRect(box, width, height)
      const el = document.createElementNS(svgNS, "rect")
      el.setAttribute("x", rect.x)
      el.setAttribute("y", rect.y)
      el.setAttribute("width", Math.max(rect.w, 6))
      el.setAttribute("height", Math.max(rect.h, 6))
      el.setAttribute("rx", "3")
      el.setAttribute("class", "rv-box")
      el.style.stroke = this.colorFor(box.verdict)
      el.style.pointerEvents = "all"
      el.dataset.boxIndex = this.current.boxes.indexOf(box)
      el.addEventListener("pointerenter", () => this.highlightFromBox(el.dataset.boxIndex))
      el.addEventListener("pointerleave", () => this.clearHighlight())
      this.svgTarget.appendChild(el)
    })
  }

  scaledRect(box, width, height) {
    const [ basisW, basisH ] = box.basis || [ 1000, 1000 ]
    const [ x, y, w, h ] = box.bbox
    return {
      x: x * width / basisW,
      y: y * height / basisH,
      w: w * width / basisW,
      h: h * height / basisH
    }
  }

  // --- evidence inspector --------------------------------------------------

  renderInspector(payload) {
    const findings = payload.findings || []
    const boxIndexByField = new Map()
    ;(payload.boxes || []).forEach((box, index) => {
      [ box.field, ...(box.related_fields || []) ].forEach((field) => {
        if (!boxIndexByField.has(field)) boxIndexByField.set(field, index)
      })
    })

    const sections = this.constructor.GROUPS.map((group) => {
      const rows = findings.filter((f) => group.verdicts.includes(f.verdict))
      if (rows.length === 0) return ""

      const items = rows.map((finding) => {
        const boxIndex = boxIndexByField.get(finding.field)
        const located = boxIndex !== undefined
        const color = this.colorFor(finding.verdict)
        return `
          <li>
            <button type="button"
                    data-action="review-mode#toggleRow mouseenter->review-mode#rowEntered mouseleave->review-mode#clearHighlight focus->review-mode#rowEntered blur->review-mode#clearHighlight"
                    ${located ? `data-box-index="${boxIndex}"` : ""}
                    aria-expanded="false"
                    class="w-full flex items-center gap-2.5 px-4 py-2.5 text-left cursor-pointer
                           transition duration-150 hover:bg-raised focus-visible:outline-2
                           focus-visible:-outline-offset-2 focus-visible:outline-focus">
              <span class="shrink-0 size-2 rounded-full" style="background: ${color}" aria-hidden="true"></span>
              <span class="flex-1 min-w-0 truncate text-sm font-medium">${this.escape(finding.label)}</span>
              ${located ? "" : `<span class="shrink-0 text-xs px-1.5 py-0.5 rounded border border-dashed text-ink-faint border-line-strong">not on label</span>`}
              <svg class="shrink-0 size-3.5 text-ink-faint transition-transform duration-150" viewBox="0 0 16 16" fill="none" aria-hidden="true" data-chevron>
                <path d="M6 4l4 4-4 4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
              </svg>
            </button>
            <div class="hidden px-4 pb-3 pt-0.5" data-row-detail>
              ${this.detailHtml(finding)}
            </div>
          </li>`
      }).join("")

      return `
        <section aria-label="${this.escape(group.title)}">
          <h3 class="sticky top-0 z-10 flex items-baseline gap-2 px-4 pt-4 pb-1.5 bg-panel
                     text-xs font-semibold uppercase tracking-wider"
              style="color: ${this.colorFor(group.verdicts[0])}">
            ${this.escape(group.title)}
            <span class="text-ink-faint font-normal normal-case tracking-normal">${rows.length}</span>
          </h3>
          <ul class="divide-y divide-line/60">${items}</ul>
        </section>`
    }).join("")

    this.inspectorTarget.innerHTML = `
      <div class="overflow-y-auto min-h-0 flex-1 pb-4" data-inspector-scroll>
        ${sections || `<p class="px-4 py-6 text-sm text-ink-muted">No checks were evaluated.</p>`}
      </div>`
  }

  detailHtml(finding) {
    const value = (text) => text
      ? `<dd class="text-sm">${this.escape(text)}</dd>`
      : `<dd class="text-sm text-ink-faint">—</dd>`
    return `
      <dl class="space-y-2 border-l border-line pl-3 ml-0.5">
        <div>
          <dt class="text-xs uppercase tracking-wide text-ink-faint">Application</dt>
          ${value(finding.expected)}
        </div>
        <div>
          <dt class="text-xs uppercase tracking-wide text-ink-faint">On the label</dt>
          ${value(finding.extracted)}
        </div>
        ${finding.note ? `<p class="text-sm text-ink-muted">${this.escape(finding.note)}</p>` : ""}
        ${finding.citation ? `<p class="text-xs text-ink-faint">${this.escape(finding.citation)}</p>` : ""}
      </dl>`
  }

  // Single-open accordion: the unfolded row is the one being judged.
  toggleRow(event) {
    const button = event.currentTarget
    const detail = button.nextElementSibling
    const wasOpen = !detail.classList.contains("hidden")

    this.inspectorTarget.querySelectorAll("[data-row-detail]").forEach((el) => el.classList.add("hidden"))
    this.inspectorTarget.querySelectorAll("[aria-expanded]").forEach((el) => {
      el.setAttribute("aria-expanded", "false")
      el.querySelector("[data-chevron]")?.classList.remove("rotate-90")
    })

    if (!wasOpen) {
      detail.classList.remove("hidden")
      button.setAttribute("aria-expanded", "true")
      button.querySelector("[data-chevron]")?.classList.add("rotate-90")
      this.highlightBox(button.dataset.boxIndex)
    } else {
      this.clearHighlight()
    }
  }

  rowEntered(event) {
    this.highlightBox(event.currentTarget.dataset.boxIndex)
  }

  // Hovering a row spotlights its box; all other boxes recede.
  highlightBox(boxIndex) {
    if (boxIndex === undefined || boxIndex === null || boxIndex === "") return
    this.svgTarget.querySelectorAll(".rv-box").forEach((el) => {
      const active = el.dataset.boxIndex === String(boxIndex)
      el.dataset.active = active
      el.dataset.faded = !active
    })
  }

  // Hovering a box highlights its inspector rows.
  highlightFromBox(boxIndex) {
    this.highlightBox(boxIndex)
    this.inspectorTarget.querySelectorAll(`[data-box-index="${boxIndex}"]`).forEach((row) => {
      row.classList.add("bg-raised")
      row.scrollIntoView({ block: "nearest", behavior: this.reducedMotion ? "auto" : "smooth" })
    })
  }

  clearHighlight() {
    this.svgTarget.querySelectorAll(".rv-box").forEach((el) => {
      el.dataset.active = false
      el.dataset.faded = false
    })
    this.inspectorTarget.querySelectorAll("[data-box-index]").forEach((row) => row.classList.remove("bg-raised"))
  }

  colorFor(verdict) {
    return this.constructor.VERDICT_COLORS[verdict] || this.constructor.VERDICT_COLORS.default
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
