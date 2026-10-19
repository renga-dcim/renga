import {test} from "node:test"
import assert from "node:assert/strict"
import {hooks, install} from "../../deps/renga_ui/ui/assets/js/index.js"

test("exports hooks and installs shared browser events", () => {
  const windowListeners = new Map()
  const documentListeners = new Map()
  const overlay = new EventTarget()
  let closed = false

  overlay.addEventListener("renga:overlay-close", () => {
    closed = true
  })

  class Element {}

  const win = {
    Element,
    addEventListener: (name, listener) => windowListeners.set(name, listener)
  }

  const doc = {
    addEventListener: (name, listener) => documentListeners.set(name, listener),
    getElementById: id => (id === "consumer-panel" ? overlay : null),
    querySelectorAll: () => []
  }

  install(doc, win)

  assert.deepEqual(Object.keys(hooks).sort(), ["Overlay", "TabStrip"])
  assert(windowListeners.has("resize"))
  assert(documentListeners.has("phx:update"))

  windowListeners.get("phx:close-overlay")({detail: {id: "consumer-panel"}})
  assert(closed)
})
