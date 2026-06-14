import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static values = { active: Boolean, interval: Number }

  connect() {
    this.refreshRestoredPage = this.refreshRestoredPage.bind(this)
    window.addEventListener("pageshow", this.refreshRestoredPage)

    if (this.activeValue) this.startPolling()
  }

  disconnect() {
    window.removeEventListener("pageshow", this.refreshRestoredPage)
    this.stopPolling()
  }

  refreshRestoredPage(event) {
    if (!this.activeValue || !event.persisted) return

    this.refresh()
  }

  startPolling() {
    this.poller = window.setInterval(() => this.refresh(), this.intervalValue)
  }

  stopPolling() {
    if (!this.poller) return

    window.clearInterval(this.poller)
    this.poller = null
  }

  refresh() {
    Turbo.visit(window.location.href, { action: "replace" })
  }
}
