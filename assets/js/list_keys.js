// Keyboard grammar for the shared list (RFD 8): J/K move between rows, Enter
// opens the focused row through its native link, X toggles its selection,
// and F jumps to the list's filter. Keys never fire while someone is typing
// or while a dialog (the command menu, a confirmation) is open.
const typing = "input, textarea, select, [contenteditable='true']"

export const ListKeys = {
  mounted() {
    this.onKeydown = event => this.keydown(event)
    window.addEventListener("keydown", this.onKeydown)
  },

  // Re-rendering the list replaces its rows, which drops focus. Put it back
  // on the same row so J/K and X can continue where they were.
  updated() {
    if (!this.focusedId) return
    if (document.activeElement && document.activeElement !== document.body) return
    this.focusRow(document.getElementById(this.focusedId))
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydown)
  },

  rows() {
    return Array.from(this.el.querySelectorAll("tr[data-list-row]"))
  },

  currentIndex(rows) {
    const row = document.activeElement?.closest?.("tr[data-list-row]")
    return row ? rows.indexOf(row) : -1
  },

  focusRow(row) {
    const link = row?.querySelector("a")
    if (!link) return
    this.focusedId = row.id
    link.focus()
    link.scrollIntoView?.({block: "nearest"})
  },

  keydown(event) {
    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return
    if (event.target.closest?.(typing) && !event.target.matches?.("[data-list-check]")) return
    // The command menu is a <dialog>; side panels and confirmations lock the
    // page scroll while open (see overlay.js).
    if (document.querySelector("dialog[open]")) return
    if (document.body.classList.contains("overflow-hidden")) return

    const rows = this.rows()
    const index = this.currentIndex(rows)

    switch (event.key) {
      case "j":
      case "J":
        event.preventDefault()
        this.focusRow(rows[Math.min(index + 1, rows.length - 1)])
        break
      case "k":
      case "K":
        event.preventDefault()
        this.focusRow(rows[Math.max(index - 1, 0)])
        break
      case "x":
      case "X":
        if (index === -1) return
        event.preventDefault()
        this.focusedId = rows[index].id
        rows[index].querySelector("[data-list-check]")?.click()
        break
      case "f":
      case "F": {
        const filter = this.el.dataset.filter && document.querySelector(this.el.dataset.filter)
        if (!filter) return
        event.preventDefault()
        filter.focus()
        break
      }
    }
  },
}
