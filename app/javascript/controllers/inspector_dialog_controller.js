import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog"]

  connect() {
    this.keyHandler = (event) => {
      if (event.key === "Escape" && this.dialogTarget.open) this.close()
    }
    this.closeHandler = () => this.unlockPageScroll()
    this.beforeCacheHandler = () => this.close()
    document.addEventListener("keydown", this.keyHandler)
    document.addEventListener("turbo:before-cache", this.beforeCacheHandler)
    this.dialogTarget.addEventListener("close", this.closeHandler)
  }

  disconnect() {
    document.removeEventListener("keydown", this.keyHandler)
    document.removeEventListener("turbo:before-cache", this.beforeCacheHandler)
    this.dialogTarget.removeEventListener("close", this.closeHandler)
    this.unlockPageScroll()
  }

  open() {
    if (this.dialogTarget.open) return

    this.dialogTarget.showModal()
    this.lockPageScroll()
  }

  close() {
    if (this.dialogTarget.open) this.dialogTarget.close()

    this.unlockPageScroll()
  }

  lockPageScroll() {
    document.documentElement.classList.add("overflow-hidden")
  }

  unlockPageScroll() {
    document.documentElement.classList.remove("overflow-hidden")
  }
}
