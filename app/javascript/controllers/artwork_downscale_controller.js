import { Controller } from "@hotwired/stimulus"

// Downscales oversized artwork photos in the browser before upload:
// anything whose longest edge exceeds MAX_EDGE is redrawn at that cap
// and re-encoded as JPEG. Uploads get smaller and the OCR pipeline is
// never handed a pathological raster. The cap is deliberately generous -
// fine-print recovery crops out of the original pixels, so it must stay
// well above the OCR engine's own input ceiling. Non-images (PDFs) and
// in-bounds images pass through untouched; so does anything the browser
// fails to decode - this is an optimization, never a gate.
const MAX_EDGE = 3500
const JPEG_QUALITY = 0.9

export default class extends Controller {
  async shrink() {
    const input = this.element
    if (!input.files?.length) return

    const transfer = new DataTransfer()
    for (const file of input.files) {
      transfer.items.add(await this.downscaled(file))
    }
    input.files = transfer.files
  }

  async downscaled(file) {
    if (!file.type.startsWith("image/")) return file

    try {
      const bitmap = await createImageBitmap(file, { imageOrientation: "from-image" })
      const scale = MAX_EDGE / Math.max(bitmap.width, bitmap.height)
      if (scale >= 1) {
        bitmap.close()
        return file
      }

      const canvas = document.createElement("canvas")
      canvas.width = Math.round(bitmap.width * scale)
      canvas.height = Math.round(bitmap.height * scale)
      canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height)
      bitmap.close()

      const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", JPEG_QUALITY))
      if (!blob) return file

      // The original filename is kept verbatim: batch intake matches CSV
      // rows to images by filename, and storage sniffs the real content
      // type from the bytes.
      return new File([blob], file.name, { type: "image/jpeg" })
    } catch {
      return file
    }
  }
}
