// Drag-to-place on the rack elevation (RFD 8, "Places"): drag a device from
// "Can go in this rack" onto free units of a face. The device's top lands on
// the unit under the pointer; the units it would cover are highlighted, and
// dropping only works when all of them are free. Touch screens place by
// choosing a unit from a list instead, so this is pointer-only by design.

// Which unit of a face the pointer is over, from the face's grid geometry.
export function unitAt({top, height, rows, bottomUp}, clientY) {
  const row = Math.min(rows - 1, Math.max(0, Math.floor(((clientY - top) / height) * rows)))
  return bottomUp ? rows - row : row + 1
}

// The units a device of `size` units covers when its top is at `unit`.
export function coveredUnits(unit, size, bottomUp) {
  const start = bottomUp ? unit - size + 1 : unit
  return Array.from({length: size}, (_, index) => start + index)
}

export const RackDrag = {
  mounted() {
    this.dragging = null
    this.marked = []

    this.handlers = {
      pointerdown: event => { this.pointerType = event.pointerType },
      dragstart: event => this.start(event),
      dragover: event => this.over(event),
      drop: event => this.drop(event),
      dragend: () => this.end(),
      dragleave: event => {
        if (!this.el.contains(event.relatedTarget)) this.clear()
      },
    }

    Object.entries(this.handlers).forEach(([name, handler]) => this.el.addEventListener(name, handler))
  },

  destroyed() {
    Object.entries(this.handlers).forEach(([name, handler]) => this.el.removeEventListener(name, handler))
    this.end()
  },

  start(event) {
    const item = event.target.closest?.("[data-drag-resource]")
    if (!item) return

    if (this.pointerType === "touch" || !window.matchMedia("(min-width: 1024px) and (any-pointer: fine)").matches) {
      event.preventDefault()
      this.end()
      return
    }

    this.dragging = {id: item.dataset.dragResource, size: parseInt(item.dataset.height, 10) || 1}
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", this.dragging.id)
    this.el.dataset.dragging = "true"
  },

  over(event) {
    const target = this.target(event)
    this.clear()
    if (!target) return

    target.preview.forEach(cell => {
      cell.dataset.dropTarget = target.valid ? "valid" : "invalid"
      this.marked.push(cell)
    })

    if (target.valid) {
      event.preventDefault()
      event.dataTransfer.dropEffect = "move"
    }
  },

  drop(event) {
    const target = this.target(event)
    this.clear()
    if (!target?.valid) return

    event.preventDefault()
    this.pushEvent("drop_place", {resource_id: this.dragging.id, position: target.start, face: target.face})
    this.end()
  },

  end() {
    this.dragging = null
    this.clear()
    delete this.el.dataset.dragging
  },

  clear() {
    this.marked.forEach(cell => delete cell.dataset.dropTarget)
    this.marked = []
  },

  // The face, starting unit, free unit cells, and validity for a drop at
  // the pointer, or null when the pointer is not over a face.
  target(event) {
    if (!this.dragging) return null
    const grid = event.target.closest?.("[data-rack-face]")
    if (!grid || !this.el.contains(grid)) return null

    const rows = parseInt(grid.dataset.rows, 10)
    const bottomUp = grid.dataset.bottomUp === "true"
    const rect = grid.getBoundingClientRect()
    const unit = unitAt({top: rect.top, height: rect.height, rows, bottomUp}, event.clientY)
    const units = coveredUnits(unit, this.dragging.size, bottomUp)
    const cells = units
      .map(covered => grid.querySelector(`button[data-unit="${covered}"]`))
      .filter(Boolean)

    return {
      face: grid.dataset.rackFace,
      start: Math.min(...units),
      preview: units.map(covered => grid.querySelector(`[data-drop-unit="${covered}"]`)).filter(Boolean),
      valid: cells.length === units.length && units.every(covered => covered >= 1 && covered <= rows),
    }
  },
}
