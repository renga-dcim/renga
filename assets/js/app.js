// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/renga"
import topbar from "../vendor/topbar"
import {Overlay} from "./overlay"
import {ListKeys} from "./list_keys"
import {RackDrag} from "./rack_drag"
import {CenterScroll} from "./center_scroll"
import {TabStrip} from "./tab_strip"

const CommandPalette = {
  mounted() {
    this.dialog = this.el.querySelector("#command-palette")
    this.input = this.el.querySelector("#command-palette-input")
    this.searchItem = this.el.querySelector("#command-resource-search")
    this.activeIndex = 0

    this.open = () => {
      if (!this.dialog.open) {
        this.opener = document.activeElement
        this.dialog.showModal()
      }
      this.input.value = ""
      this.updateItems()
      requestAnimationFrame(() => this.input.focus())
    }

    this.onOpen = () => this.open()
    this.onInput = () => this.updateItems()
    this.onFocus = event => {
      const item = event.target.closest("[data-command-item]")
      this.commandFocused = !!item
      if (!item) return
      this.activeIndex = this.items.indexOf(item)
      this.highlightActiveItem()
    }
    this.onClick = event => {
      if (event.target === this.dialog) this.dialog.close()

      const item = event.target.closest("[data-command-item]")
      if (!item) return
      // Unavailable actions stay open so their reason can be read.
      if (item.getAttribute("aria-disabled") === "true") return

      // The sidebar's theme button saves the choice to the account
      // (RengaWeb.AppearanceHook), so the command presses it.
      if (item.dataset.commandAction === "toggle-theme") {
        const toggle = document.getElementById("theme-toggle")
        if (toggle) toggle.click()
        else window.dispatchEvent(new CustomEvent("phx:toggle-theme"))
      }

      this.dialog.close()
    }

    this.onKeydown = event => {
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") {
        event.preventDefault()
        this.open()
        return
      }

      if (!this.dialog.open) return

      if (event.key === "Escape") {
        event.preventDefault()
        this.dialog.close()
        this.opener?.focus()
        return
      }

      if ((event.key === "ArrowDown" || event.key === "ArrowUp") && this.items.length > 0) {
        event.preventDefault()
        const offset = event.key === "ArrowDown" ? 1 : -1
        this.activeIndex = (this.activeIndex + offset + this.items.length) % this.items.length
        this.highlightActiveItem()
        const item = this.items[this.activeIndex]
        const control = item.matches("a, button") ? item : item.querySelector("a, button")
        control?.focus()
        return
      }

      // Focused controls retain native activation; only the query needs a
      // synthetic click on the highlighted result.
      if (event.key === "Enter" && event.target === this.input && this.items.length > 0) {
        event.preventDefault()
        const item = this.items[this.activeIndex]
        const control = item.matches("a, button") ? item : item.querySelector("a, button")
        control?.click()
      }
    }

    window.addEventListener("renga:open-command-palette", this.onOpen)
    window.addEventListener("keydown", this.onKeydown)
    this.input.addEventListener("input", this.onInput)
    this.dialog.addEventListener("click", this.onClick)
    this.dialog.addEventListener("focusin", this.onFocus)
  },

  // The server re-renders the menu when page actions change; restore the
  // selection by identity, not position, since commands can come and go.
  updated() {
    this.updateItems(true)
  },

  destroyed() {
    window.removeEventListener("renga:open-command-palette", this.onOpen)
    window.removeEventListener("keydown", this.onKeydown)
    this.input.removeEventListener("input", this.onInput)
    this.dialog.removeEventListener("click", this.onClick)
    this.dialog.removeEventListener("focusin", this.onFocus)
  },

  updateItems(preserveSelection = false) {
    const query = this.input.value.trim().toLowerCase()
    const searchLink = this.searchItem.querySelector("a")
    const searchLabel = this.searchItem.querySelector("[data-search-label]")

    this.searchItem.hidden = query === ""
    searchLink.href = `/inventory?q=${encodeURIComponent(query)}`
    searchLabel.textContent = `Search resources for “${this.input.value.trim()}”`

    this.el.querySelectorAll("[data-command-item]:not(#command-resource-search)").forEach(item => {
      item.hidden = query !== "" && !item.dataset.search.includes(query)
    })

    // A heading whose items are all filtered out would sit over nothing.
    this.el.querySelectorAll("[data-command-group]").forEach(group => {
      if (group.closest("[data-command-item]")) return
      let sibling = group.nextElementSibling
      let visible = false
      while (sibling && !sibling.matches("[data-command-group]")) {
        if (sibling.matches("[data-command-item]") && !sibling.hidden) visible = true
        sibling = sibling.nextElementSibling
      }
      group.hidden = !visible
    })

    this.items = Array.from(this.el.querySelectorAll("[data-command-item]:not([hidden])"))
    this.activeIndex = preserveSelection
      ? Math.max(0, this.items.findIndex(item =>
        (item.id || item.getAttribute("href") || item.dataset.commandAction) === this.activeKey))
      : 0
    this.highlightActiveItem()
    if (preserveSelection && this.dialog.open && this.commandFocused) {
      const item = this.items[this.activeIndex]
      const control = item?.matches("a, button") ? item : item?.querySelector("a, button")
      ;(control || this.input).focus()
    }
  },

  highlightActiveItem() {
    this.items.forEach((item, index) => {
      const control = item.matches("a, button") ? item : item.querySelector("a, button")
      control?.classList.toggle("bg-base-content/[0.06]", index === this.activeIndex)
    })
    const active = this.items[this.activeIndex]
    this.activeKey = active && (active.id || active.getAttribute("href") || active.dataset.commandAction)
    active?.scrollIntoView({block: "nearest"})
  },
}

const CopyToClipboard = {
  mounted() {
    this.onClick = async () => {
      const target = document.querySelector(this.el.dataset.copyTarget)
      const status = document.querySelector(this.el.dataset.copyStatus)

      try {
        if (!target || !navigator.clipboard?.writeText) throw new Error("clipboard unavailable")
        await navigator.clipboard.writeText(target.textContent.trim())
        this.el.setAttribute("aria-label", "Copied")
        this.el.querySelector("[data-copy-icon]").classList.add("hidden")
        this.el.querySelector("[data-copied-icon]").classList.remove("hidden")
        if (status) status.textContent = "Intake API key copied."
      } catch (_error) {
        this.el.setAttribute("aria-label", "Copy failed")
        if (status) status.textContent = "Could not copy. Select the key and copy it manually."
      }

      clearTimeout(this.resetTimer)
      this.resetTimer = setTimeout(() => this.reset(status), 2000)
    }

    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    clearTimeout(this.resetTimer)
    this.el.removeEventListener("click", this.onClick)
  },

  reset(status) {
    this.el.setAttribute("aria-label", "Copy intake API key")
    this.el.querySelector("[data-copy-icon]").classList.remove("hidden")
    this.el.querySelector("[data-copied-icon]").classList.add("hidden")
    if (status) status.textContent = ""
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, CenterScroll, CommandPalette, CopyToClipboard, Overlay, ListKeys, RackDrag, TabStrip},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#ea580c"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Lets the server close a side panel or dialog once its action succeeded
// (see RengaWeb.UI.close_overlay/2), keeping it open on validation errors.
window.addEventListener("phx:close-overlay", ({detail}) => {
  document.getElementById(detail.id)?.dispatchEvent(new Event("renga:overlay-close"))
})

// Applies appearance changes made during a session (RFD 8, "Visual design"):
// the root layout renders the saved theme, accent and density onto <html>,
// and RengaWeb.AppearanceHook pushes them again when they change.
window.addEventListener("phx:appearance", ({detail}) => {
  const root = document.documentElement
  root.dataset.accent = detail.accent
  root.dataset.density = detail.density
  root.dataset.themePref = detail.theme
  if (detail.theme === "system") {
    root.removeAttribute("data-theme")
  } else {
    root.dataset.theme = detail.theme
  }
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
