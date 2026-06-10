import { Controller } from "@hotwired/stimulus"

// Copies the source element's text to the clipboard, with a brief
// confirmation on the button.
export default class extends Controller {
  static targets = ["source", "button"]

  copy() {
    navigator.clipboard.writeText(this.sourceTarget.textContent.trim()).then(() => {
      const original = this.buttonTarget.textContent
      this.buttonTarget.textContent = "Copied"
      setTimeout(() => { this.buttonTarget.textContent = original }, 1500)
    })
  }
}
