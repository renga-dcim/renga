// Floating text for the overflow pattern (docs/design-system.md, "Overflow").
//
// Rows stay on one line, so long values end in an ellipsis. Any element
// marked `data-clip` shows its full text in a tooltip on hover (after a
// short delay) or keyboard focus, but only while it is actually cut off.
// Popovers marked `data-anchor` (the +N chip lists) open next to the
// element named by that id instead of the viewport center.
//
// Both use the native popover top layer, so they are never clipped by a
// table's scroll container or hidden under a side panel. The listeners are
// delegated from the document, so rows patched in by LiveView need no hook.

const TOOLTIP_DELAY_MS = 400
const GAP = 4
const MARGIN = 8

const TOOLTIP_CLASS =
  "pointer-events-none fixed inset-auto m-0 max-w-sm rounded-md border border-edge bg-surface " +
  "px-2.5 py-1.5 text-xs text-fg shadow-lg"

const FOCUS_OWNER_SELECTOR =
  "a, button, input, select, textarea, summary, label, [contenteditable='true'], " +
  "[tabindex]:not([tabindex='-1'])"

const INTERACTIVE_DESCENDANT_SELECTOR = `${FOCUS_OWNER_SELECTOR}, [phx-click]`

// Places a floating box below its anchor, flipping above when there is no
// room below, and keeps it inside the viewport horizontally.
export function place(anchor, box, viewport) {
  const below = anchor.bottom + GAP
  const above = anchor.top - GAP - box.height
  const fitsBelow = below + box.height <= viewport.height - MARGIN
  const top = fitsBelow || above < MARGIN ? below : above
  const maxLeft = Math.max(MARGIN, viewport.width - MARGIN - box.width)
  const left = Math.min(Math.max(anchor.left, MARGIN), maxLeft)

  return {top, left}
}

export function clipped(el) {
  return el.scrollWidth > el.clientWidth
}

export function installFloating(doc = document, win = window) {
  let tooltip = null
  let pending = null
  let timer = null
  let touchRevealed = null
  let suppressedTouchClick = null

  const clipAt = node => (node instanceof win.Element ? node.closest("[data-clip]") : null)

  const focusedClip = () => {
    const active = doc.activeElement
    if (!(active instanceof win.Element) || active === doc.body) return null
    return clipAt(active) || active.querySelector?.("[data-clip]")
  }

  const focusOwner = target =>
    target.parentElement?.closest(FOCUS_OWNER_SELECTOR)

  const interactiveDescendant = (node, target) => {
    const owner =
      node instanceof win.Element ? node.closest(INTERACTIVE_DESCENDANT_SELECTOR) : null
    return owner && owner !== target && target.contains(owner)
  }

  const syncClipFocus = target => {
    if (!target.matches("[data-clip-focus]")) return

    target.tabIndex = !focusOwner(target) && clipped(target) ? 0 : -1
  }

  const resizeObserver =
    typeof win.ResizeObserver === "function"
      ? new win.ResizeObserver(entries => entries.forEach(({target}) => syncClipFocus(target)))
      : null

  const observeClips = root => {
    const clips = []
    if (root instanceof win.Element && root.matches("[data-clip-focus]")) clips.push(root)
    clips.push(...(root.querySelectorAll?.("[data-clip-focus]") || []))

    for (const target of clips) {
      syncClipFocus(target)
      resizeObserver?.observe(target)
    }
  }

  observeClips(doc)

  if (typeof win.MutationObserver === "function") {
    const mutations = new win.MutationObserver(records => {
      for (const record of records) {
        for (const node of record.addedNodes) observeClips(node)
      }
    })
    mutations.observe(doc.documentElement, {childList: true, subtree: true})
  }

  if (!resizeObserver) {
    win.addEventListener("resize", () => observeClips(doc))
  }

  // A fixed-width value may change without triggering ResizeObserver.
  doc.addEventListener("phx:update", () => observeClips(doc))

  const ensureTooltip = () => {
    if (tooltip?.isConnected) return tooltip
    tooltip = doc.createElement("div")
    tooltip.id = "clip-tooltip"
    tooltip.className = TOOLTIP_CLASS
    tooltip.setAttribute("popover", "manual")
    tooltip.setAttribute("role", "tooltip")
    // The full text is already in the clipped element for assistive
    // technology; the tooltip only repeats it visually.
    tooltip.setAttribute("aria-hidden", "true")
    doc.body.appendChild(tooltip)
    return tooltip
  }

  const position = (el, anchor) => {
    const viewport = {width: win.innerWidth, height: win.innerHeight}
    const {top, left} = place(anchor.getBoundingClientRect(), el.getBoundingClientRect(), viewport)
    el.style.top = `${top}px`
    el.style.left = `${left}px`
  }

  const show = target => {
    if (!target.isConnected || !clipped(target)) return
    const el = ensureTooltip()
    el.textContent = target.textContent.trim().replace(/\s+/g, " ")
    if (!el.matches(":popover-open")) el.showPopover()
    position(el, target)
  }

  const hide = () => {
    clearTimeout(timer)
    pending = null
    if (tooltip?.matches(":popover-open")) tooltip.hidePopover()
  }

  doc.addEventListener("pointerover", event => {
    if (pending && clipped(pending) && focusedClip() === pending) return
    const target = clipAt(event.target)
    if (target === pending) return
    hide()
    if (!target) return
    pending = target
    // The pointer may have left by the time the delay ends, without a
    // pointerout (the page scrolled under it).
    timer = setTimeout(() => target.matches(":hover") && show(target), TOOLTIP_DELAY_MS)
  })

  doc.addEventListener("pointerout", event => {
    if (pending && clipped(pending) && focusedClip() === pending) return
    if (clipAt(event.relatedTarget) !== pending) hide()
  })

  // A row link holds its clipped text, so focus lands on the parent.
  doc.addEventListener("focusin", event => {
    hide()
    const target = clipAt(event.target) || event.target.querySelector?.("[data-clip]")
    if (!target) return
    pending = target
    win.requestAnimationFrame(() => {
      const active = doc.activeElement
      if (pending === target && (active === target || active?.contains(target))) show(target)
    })
  })

  doc.addEventListener("focusout", hide)
  doc.addEventListener("keydown", event => event.key === "Escape" && hide())

  const activateClip = event => {
    const target = clipAt(event.target)

    // The first touch on a clipped link reveals its full label without
    // navigating; a second touch keeps the link's normal behavior.
    if (event.type === "click" && target && target === suppressedTouchClick) {
      suppressedTouchClick = null
      event.preventDefault()
      event.stopImmediatePropagation()
      return
    }

    if (
      !target?.matches("[data-clip-focus]") ||
      focusOwner(target) ||
      interactiveDescendant(event.target, target) ||
      !clipped(target)
    ) {
      return
    }

    if (event.type === "pointerup" && event.pointerType === "touch" && target.matches("a[href]")) {
      if (touchRevealed === target) {
        touchRevealed = null
      } else {
        touchRevealed = target
        suppressedTouchClick = target
      }
    }

    // The row keeps its ordinary click behavior while text fits. A clipped
    // value owns this click instead so touch reveals it rather than navigating.
    if (event.type === "click") event.stopPropagation()

    target.focus({preventScroll: true})
    show(target)
  }

  // pointerup runs before LiveView handles the no-op phx-click that keeps a
  // clipped cell from triggering its row. click also covers keyboard input.
  doc.addEventListener("pointerup", activateClip)
  doc.addEventListener("click", activateClip)

  doc.addEventListener(
    "toggle",
    event => {
      const el = event.target
      if (event.newState !== "open" || !el.dataset?.anchor) return
      const anchor = doc.getElementById(el.dataset.anchor)
      if (anchor) position(el, anchor)
    },
    true
  )

  // Floating boxes are placed once, so scrolling would leave them behind.
  // A pending tooltip survives: hovering often scrolls the target into view.
  doc.addEventListener(
    "scroll",
    event => {
      if (tooltip?.matches(":popover-open")) tooltip.hidePopover()

      if (pending && focusedClip() === pending) {
        const target = pending
        win.requestAnimationFrame(() => pending === target && show(target))
      }

      for (const el of doc.querySelectorAll("[data-anchor]:popover-open")) {
        if (!el.contains(event.target)) el.hidePopover()
      }
    },
    true
  )
}
