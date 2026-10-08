// The stack owns focus and scroll locking; hidden siblings never handle Escape.
const openOverlays = []

export const Overlay = {
  mounted() {
    this.onOpen = () => {
      if (openOverlays.includes(this)) return
      this.opener = document.activeElement
      openOverlays.push(this)
      this.el.inert = false
      this.liveSocket.execJS(this.el, this.el.dataset.show)
      document.body.classList.add("overflow-hidden")
    }
    this.onClose = () => {
      const index = openOverlays.indexOf(this)
      if (index === -1) return
      const active = index === openOverlays.length - 1
      openOverlays.splice(index, 1)
      this.el.inert = true
      this.liveSocket.execJS(this.el, this.el.dataset.hide)
      if (openOverlays.length === 0) document.body.classList.remove("overflow-hidden")
      if (active && this.opener?.isConnected) this.opener.focus()
    }
    this.onCancel = () => {
      if (openOverlays.at(-1) !== this) return
      this.onClose()
      this.liveSocket.execJS(this.el, this.el.dataset.cancel)
    }
    this.onKeydown = event => {
      if (event.key !== "Escape" || openOverlays.at(-1) !== this) return
      event.preventDefault()
      event.stopImmediatePropagation()
      this.onCancel()
    }
    this.onClick = event => {
      const container = document.getElementById(`${this.el.id}-container`)
      if (!container.contains(event.target)) this.onCancel()
    }
    this.el.addEventListener("renga:overlay-open", this.onOpen)
    this.el.addEventListener("renga:overlay-close", this.onClose)
    this.el.addEventListener("renga:overlay-cancel", this.onCancel)
    this.el.addEventListener("click", this.onClick)
    window.addEventListener("keydown", this.onKeydown)
    if (this.el.dataset.initialShow === "true") this.onOpen()
  },

  destroyed() {
    this.onClose()
    this.el.removeEventListener("renga:overlay-open", this.onOpen)
    this.el.removeEventListener("renga:overlay-close", this.onClose)
    this.el.removeEventListener("renga:overlay-cancel", this.onCancel)
    this.el.removeEventListener("click", this.onClick)
    window.removeEventListener("keydown", this.onKeydown)
  },
}
