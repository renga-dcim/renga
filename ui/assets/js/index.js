// The hooks and browser wiring the shared components rely on (RengaUI).
import {Overlay} from "./overlay.js"
import {TabStrip} from "./tab_strip.js"
import {installFloating} from "./floating.js"

export {Overlay, TabStrip, installFloating}

// Spread into the LiveSocket's hooks.
export const hooks = {Overlay, TabStrip}

// Call once at boot: tooltips for clipped text, anchored +N popovers, and
// the server-side close of a side panel or dialog once its action succeeded
// (see RengaUI.Components.close_overlay/2), which keeps it open on
// validation errors.
export function install(doc = document, win = window) {
  installFloating(doc, win)
  win.addEventListener("phx:close-overlay", ({detail}) => {
    doc.getElementById(detail.id)?.dispatchEvent(new Event("renga:overlay-close"))
  })
}
