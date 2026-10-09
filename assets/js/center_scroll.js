// Opens a horizontally scrolling element at its middle (RFD 8, "Topology").
// The topology map is laid out around its centre, so on a narrow screen the
// interesting part starts out of view. This runs once on mount; later updates
// keep wherever the reader has panned to.
export const CenterScroll = {
  mounted() {
    this.el.scrollLeft = (this.el.scrollWidth - this.el.clientWidth) / 2
  },
}
