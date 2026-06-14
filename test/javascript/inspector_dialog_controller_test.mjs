import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"

const controllerPath = new URL("../../app/javascript/controllers/inspector_dialog_controller.js", import.meta.url)

test("disconnecting an open inspector releases the page scroll lock", () => {
  const environment = buildControllerEnvironment()
  const dialog = new FakeDialog()
  const controller = new environment.ControllerClass()
  Object.defineProperty(controller, "dialogTarget", { value: dialog })

  controller.connect()
  controller.open()

  assert.equal(environment.document.documentElement.classList.contains("overflow-hidden"), true)

  controller.disconnect()

  assert.equal(environment.document.documentElement.classList.contains("overflow-hidden"), false)
})

test("turbo before cache releases the page scroll lock", () => {
  const environment = buildControllerEnvironment()
  const dialog = new FakeDialog()
  const controller = new environment.ControllerClass()
  Object.defineProperty(controller, "dialogTarget", { value: dialog })

  controller.connect()
  controller.open()

  assert.equal(environment.document.documentElement.classList.contains("overflow-hidden"), true)

  environment.document.dispatchEvent("turbo:before-cache")

  assert.equal(environment.document.documentElement.classList.contains("overflow-hidden"), false)

  controller.disconnect()
})

function buildControllerEnvironment() {
  const document = new FakeDocument()
  const source = readFileSync(controllerPath, "utf8")
  const executableSource = source
    .replace('import { Controller } from "@hotwired/stimulus"', "const Controller = class {}")
    .replace("export default class extends Controller", "ControllerUnderTest = class extends Controller")
  const factory = new Function("document", `
    let ControllerUnderTest
    ${executableSource}
    return ControllerUnderTest
  `)

  return { ControllerClass: factory(document), document }
}

class FakeClassList {
  constructor() {
    this.values = new Set()
  }

  add(value) {
    this.values.add(value)
  }

  remove(value) {
    this.values.delete(value)
  }

  contains(value) {
    return this.values.has(value)
  }
}

class FakeDocument {
  constructor() {
    this.documentElement = { classList: new FakeClassList() }
    this.listenersByType = new Map()
  }

  addEventListener(type, listener) {
    const listeners = this.listenersByType.get(type) || []
    listeners.push(listener)
    this.listenersByType.set(type, listeners)
  }

  removeEventListener(type, listener) {
    const listeners = this.listenersByType.get(type) || []
    this.listenersByType.set(type, listeners.filter((existing) => existing !== listener))
  }

  dispatchEvent(type) {
    const listeners = this.listenersByType.get(type) || []
    for (const listener of listeners) listener({ type })
  }
}

class FakeDialog {
  constructor() {
    this.open = false
    this.listenersByType = new Map()
  }

  showModal() {
    this.open = true
  }

  close() {
    if (!this.open) return

    this.open = false
    this.dispatchEvent("close")
  }

  addEventListener(type, listener) {
    const listeners = this.listenersByType.get(type) || []
    listeners.push(listener)
    this.listenersByType.set(type, listeners)
  }

  removeEventListener(type, listener) {
    const listeners = this.listenersByType.get(type) || []
    this.listenersByType.set(type, listeners.filter((existing) => existing !== listener))
  }

  dispatchEvent(type) {
    const listeners = this.listenersByType.get(type) || []
    for (const listener of listeners) listener({ type })
  }
}
