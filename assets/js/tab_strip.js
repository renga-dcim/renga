// Keeps the current tab in view on a horizontally scrolling tab strip
// (RFD 8, "Phone and tablet"). On a phone an object page's tabs scroll
// sideways in one row, so after moving to a later tab it would otherwise
// sit half off screen.
export const TabStrip = {
  mounted() {
    this.reveal()
  },

  updated() {
    this.reveal()
  },

  reveal() {
    const tab = this.el.querySelector("[aria-current=page]")
    if (!tab) return

    const strip = this.el.getBoundingClientRect()
    const box = tab.getBoundingClientRect()

    if (box.left < strip.left) this.el.scrollLeft += box.left - strip.left
    else if (box.right > strip.right) this.el.scrollLeft += box.right - strip.right
  },
}
