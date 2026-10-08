import {test} from "node:test"
import assert from "node:assert/strict"
import {Overlay} from "./overlay.js"

test("only the open overlay cancels; repeated close preserves focus and scroll", () => {
  globalThis.window = new EventTarget()
  const classes = new Set()
  const opener = {isConnected: true, focus() { document.activeElement = this }}
  globalThis.document = {
    activeElement: opener,
    body: {classList: {add: name => classes.add(name), remove: name => classes.delete(name)}},
    getElementById: () => ({contains: target => target === "inside"}),
  }
  const commands = []
  function mount(id) {
    const el = Object.assign(new EventTarget(), {
      id, dataset: {show: `${id}:show`, hide: `${id}:hide`, cancel: `${id}:cancel`},
    })
    const hook = {...Overlay, el, liveSocket: {execJS: (_el, command) => {
      commands.push(command)
      if (command.endsWith(":show")) document.activeElement = {isConnected: true, focus() {}}
    }}}
    hook.mounted()
    return hook
  }
  const panel = mount("panel")
  const sibling = mount("sibling")
  const escape = () => window.dispatchEvent(Object.assign(new Event("keydown"), {key: "Escape"}))
  escape()
  assert.deepEqual(commands, [])
  sibling.onClose()
  panel.onOpen()
  panel.onOpen()
  sibling.onClose()
  assert.deepEqual(commands, ["panel:show"])
  assert(classes.has("overflow-hidden"))
  escape()
  assert.deepEqual(commands, ["panel:show", "panel:hide", "panel:cancel"])
  assert.equal(document.activeElement, opener)
  assert(!classes.has("overflow-hidden"))
  panel.onClose()
  escape()
  assert.equal(commands.length, 3)

  panel.onOpen()
  panel.onClick({target: "inside"})
  assert.equal(commands.at(-1), "panel:show")
  panel.onClick({target: "outside"})
  assert.equal(commands.at(-1), "panel:cancel")
  assert.equal(document.activeElement, opener)
  panel.destroyed()
  sibling.destroyed()
  escape()
  assert.equal(commands.length, 6)
})
