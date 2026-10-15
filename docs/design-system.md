# Design system

This is the working reference for building Renga screens. The decisions behind
it are in [RFD 8, "Product experience"](../rfd/0008/README.adoc) (especially
"Shared patterns", "Visual design", and "Phone and tablet"); this guide turns
them, and the conventions the shipped screens already follow, into rules a new
screen can apply without reverse-engineering existing code.

To see it rendered, run the app in development (`mix phx.server`) and open
[`/dev/design-system`](http://localhost:4401/dev/design-system). The page
draws every token and shared component with the real CSS, and its switches
preview each accent, theme, and density without saving anything. Its source is
[`RengaWeb.DesignSystemLive`](../lib/renga_web/live/design_system_live.ex);
add a sample there when you add a token or a shared component.

The system has four parts, and each has one home:

| Part | Lives in | Owns |
|---|---|---|
| Tokens | [`assets/css/tokens.css`](../assets/css/tokens.css) | Every color, status color, and density value, per accent and theme |
| Tailwind names | [`assets/css/app.css`](../assets/css/app.css) (`@theme inline`) | The class names screens use (`bg-surface`, `h-row`, `text-table`, ...) |
| Components | [`RengaWeb.CoreComponents`](../lib/renga_web/components/core_components.ex), [`RengaWeb.UI`](../lib/renga_web/components/ui.ex), and the domain component modules | Markup and behavior that must look the same everywhere |
| Guard | [`test/renga_web/components/design_system_test.exs`](../test/renga_web/components/design_system_test.exs) | Fails the build on raw colors and off-scale values |

When this guide and a component disagree, the component wins and this guide
is out of date: fix the guide in the same change.

## Rules of thumb

1. Compose a shared component before writing markup. If two domains need the
   same piece, it belongs in `RengaWeb.UI` (or a domain component module), not
   in two LiveViews.
2. Style only with token names. Never use Tailwind's palette (`bg-orange-500`,
   `text-gray-600`), `white`/`black`, hex values, or the former daisyUI names
   (`bg-base-100`, `text-base-content/60`, `btn-primary`). Those ignore the
   person's accent and theme.
3. Never handle density or theme in a screen. Use `h-row`, `h-control`,
   `px-cell`, `text-table`, and the `rack-u` spacing; the tokens do the rest.
4. Status colors (`ok`, `warn`, `crit`, `info`, `unknown`) mean health only,
   and always come with a shape or text. Never use them for decoration, and
   never use the accent to mean status.
5. Every interactive element keeps `min-h-tap` (44px on touch screens), shows
   `focus-visible:ring-4 focus-visible:ring-ring`, and has an accessible name.
6. Table rows stay on one line at the row height. Long values end in an
   ellipsis instead of wrapping; see [Overflow](#overflow).

## Color

Screens use the Tailwind names on the left. Each one resolves to a
`--rg-*` custom property that changes with `data-accent`, `data-theme`, and the
system color scheme, set on `<html>`.

### Surfaces and text

| Name | Use |
|---|---|
| `canvas` | Page background behind content |
| `surface` | Cards, panels, tables, inputs, dialogs: anything that sits on the canvas |
| `sunken` | Sidebar, hover fill, selected segment, inset wells, `kbd` |
| `nav-active` | The current item in the sidebar |
| `edge` | Borders and outlines of surfaces and controls |
| `line` | Quiet rules between rows inside a surface (`divide-line`) |
| `fg` | Primary text and icons |
| `fg-muted` | Secondary text, labels, inactive tabs |
| `fg-subtle` | Tertiary text, placeholders, decorative icons, empty values |

### Accent

| Name | Use |
|---|---|
| `accent` / `accent-fg` | Primary buttons and the one most important mark on a screen |
| `accent-hover` | Hover state of `accent` fills (derived, never set by hand) |
| `accent-tint` | Quiet background for an accent-selected item |
| `link` | Inline text links |
| `ring` | Focus rings (derived from the accent) |

Each person picks one of five accents (Copper, the default; Petrol, Cobalt,
Iris, Monochrome), so the accent must never carry meaning beyond "primary".

### Status

Status colors are the same for every accent, and each has a light and a dark
value. Use the `-text` variant for text on a light background and the `-fill`
and `-line` variants for a tinted badge or banner.

| Signal | Classes | Meaning |
|---|---|---|
| OK | `ok` | Healthy, active, connected |
| Warning | `warn`, `warn-text`, `warn-fill`, `warn-line` | Stale data, drift, needs attention. Ochre, never amber, so it is never mistaken for Copper |
| Critical | `crit`, `crit-fill`, `crit-line` | Failures, lost agents, destructive actions |
| Info | `info`, `info-fill` | Planned or informational state |
| Unknown | `unknown` | No evidence, retired, inactive |

Every status pairs a color with a shape so it reads in grayscale. The status
strip (`RengaWeb.UI.status_strip/1`) is the reference:

| Shape | Meaning |
|---|---|
| Filled dot (`size-2 rounded-full bg-ok`) | Present and healthy |
| Ring (`size-2 rounded-full border-[1.5px] border-info`) | Planned, absent, or lost (ring color says which) |
| Clock icon tinted by freshness | Inventory freshness |
| `≠ N` badge on `warn-fill` | Open drift findings |

Overlay scrims use `bg-fg/25`. The command palette's native `<dialog>` uses
`backdrop:bg-black/60`, which the guard allows as a single exception.

## Typography

Fonts are the system stacks in `app.css`: `font-sans` for everything and
`font-mono` for machine values (identifiers, serials, IP addresses, MACs,
counts, keyboard hints, and object-page subtitles).

| Class | Role |
|---|---|
| `text-xl font-semibold tracking-tight` | Page title (object, settings, sign-in pages) |
| `text-lg font-semibold tracking-tight` | `<.header>` title |
| `text-base font-semibold` | Dialog and side-panel titles |
| `text-sm` | Body text, controls, properties, tabs |
| `text-table` | Table cells (follows density: 13px comfortable, 12px compact) |
| `text-xs` | Labels, row metadata, the status strip, sidebar items, help text |
| `text-[11px]` | Counts on tabs, inline badges, avatar initials |
| `text-[10px]` | Keyboard hints, section overlines, rack-unit labels |

Weights: `font-medium` for labels and the active item, `font-semibold` for
titles. Section overlines are
`text-[10px] font-semibold uppercase tracking-[0.12em] text-fg-subtle`. Use
sentence case everywhere else. The guard rejects any other arbitrary pixel
size; if a design needs one, add it to this scale first.

## Spacing and density

Use Tailwind's spacing scale. The common steps are `gap-1.5`, `gap-2`, and
`gap-3` inside a row, `space-y-2` to `space-y-3` inside a group, and
`space-y-5` to `space-y-6` between page sections. Pages pad `px-6 py-6`
(`lg:px-8`); panels and dialogs pad `px-5 py-4`.

Density changes only these tokens, which shared components consume:

| Class | Comfortable | Compact | Used by |
|---|---|---|---|
| `h-row` | 36px | 28px | Table rows |
| `h-control` | 32px | 28px | Buttons (`md`) and inputs |
| `px-cell` | 12px | 10px | Table cell padding |
| `text-table` | 13px | 12px | Table text |
| `rack-u` (`var(--spacing-rack-u)`) | 16px | 12px | One rack unit in an elevation |
| `min-h-tap` / `min-w-tap` | 0 | 0 | 44px on coarse pointers at either density |

## Shape and elevation

| Radius | Use |
|---|---|
| `rounded-sm` | Small tags (`text-[11px]` chips), rack device blocks, usage bars, focus outlines on row links |
| `rounded` | Elements inside a control: segment options, `kbd`, the drift badge |
| `rounded-md` | Buttons, inputs, nav items, menu rows |
| `rounded-lg` | Cards, panels, popover menus, icon tiles |
| `rounded-xl` | Dialogs, the command palette, the sign-in card |
| `rounded-full` | Status dots, avatars, pills, progress tracks |

`rounded-2xl` and larger are not part of the scale.

Surfaces are separated by borders, not shadows. A card is
`rounded-lg border border-edge bg-surface`; a list inside one adds
`divide-y divide-line`. Shadows are reserved for things that float:
`shadow-sm` for the sign-in card, `shadow-lg` for flashes and dropdown
menus, tooltips and popovers, `shadow-xl` for the mobile navigation menu, and `shadow-2xl` for
dialogs and side panels.

## Interaction

- Hover: `hover:bg-sunken` on neutral targets, `hover:text-fg` on muted text,
  `hover:bg-accent-hover` on accent fills. Animate with `transition-colors`.
- Focus: `focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring`;
  inputs also take `focus:border-accent`.
  `app.css` gives any link, button, or `summary` without its own focus style
  the same 4px ring color as an outline, so nothing is ever unmarked; shared
  components still set the ring explicitly.
- Disabled: `disabled:opacity-50 disabled:cursor-not-allowed`. An unavailable
  action stays visible and says why (RFD 8, "Actions").
- Loading: `phx-submit-loading:opacity-70` on submit buttons, plus the
  `phx-click-loading` and `phx-change-loading` variants defined in `app.css`.
- Overlays open and close over 150ms with opacity transitions
  (`RengaWeb.UI.show_overlay/2`, `hide_overlay/2`).
- Create and edit happen in a side panel or dialog, never in an always-open
  form on the page. Destructive actions confirm with a `danger` dialog.

## Overflow

Rows never wrap, and never stack a second line of metadata under a value:
mixed one- and two-line rows make a list hard to scan. When text does not fit,
it is cut, and the full value stays one hover, focus, or touch away.

- **Long text** ends in an ellipsis. While it is actually cut off, hovering it
  for 400ms, focusing it, or touching it shows the whole value in a tooltip
  (`rounded-md border border-edge bg-surface text-xs shadow-lg`). Text that
  fits shows no tooltip. Use `<.clip>` for a single value; tables do this for
  every cell with `overflow="clip"`. The full text stays in the markup, so
  screen readers never need the tooltip.
- **Secondary values** (a hostname after a name, a version after an agent) sit
  inline after the primary value in `font-mono text-xs text-fg-muted`, so they
  are the first thing to be cut.
- **Several tags** in one cell collapse to the first and a `+N` chip
  (`<.chip_list>`). The chip is a button that opens every item in a popover,
  where each item can carry more detail, such as a capability's risk class.
- **Narrow tables** drop columns instead of squeezing every column or
  scrolling sideways. Mark the columns that can go with `hide_below`, in the
  order they should go: details and reasons first, then durations and people.
  The name or target and the state never hide. Sizes are container sizes
  (`@xl` is 576px, `@3xl` is 768px), so a table in a side panel drops columns
  as early as one on a phone.

Tooltips and popovers use the native popover layer
(`assets/js/floating.js`), so a table's scroll container or a side panel
never clips them. They close on Escape, on scroll, and (popovers) on a click
outside.

## Icons

Use `<.icon name="hero-...">` from Heroicons. Prefer the `-mini` set at
`size-4` (controls, menus, list rows) or `size-3.5` (inline with `text-xs`);
`size-5` is for the mobile header. Decorative icons take `text-fg-subtle` or
`text-fg-muted`. An icon renders as an empty `<span>`, so an icon-only button
needs an `aria-label`.

## Brand

The logo lives in [`RengaWeb.Brand`](../lib/renga_web/components/brand.ex) and
draws inline, so it follows the accent and theme. Never use a Heroicon in its
place.

| Component | Use | Smallest |
|---|---|---|
| `<Brand.wordmark />` | The name wherever it appears in the app: sidebar, headers. The R takes the accent and "enga" takes the text color. `caps` sets "ENGA" for label-like uses; `tone={:one}` drops the accent | 18px tall |
| `<Brand.mark />` | The R on its own, beside other text | 20px |
| `<Brand.mark variant={:inverted} />` | The R left as a gap in a brick wall, for larger standalone uses | 24px |
| `<Brand.mark variant={:tile} />` | The inverted wall trimmed to a rounded square: the app icon. The sign-in card, and the favicon (`priv/static/favicon.svg`) | 16px |

Below 20px use the tile. Size the SVG with a height class and let the
width follow; never stretch it or re-space the bricks. Keep one course (about a
fifth of the mark's height) clear around it, and don't color single bricks or
use a status color on them.

## Components

Reach for these before writing markup. Each module documents its attributes
and examples in its `@doc`.

| Need | Component |
|---|---|
| Button or button-styled link | `<.button>` with `variant` `primary`, `secondary` (default), `ghost`, or `danger`, and `size` `md` or `sm` |
| Form field | `<.input>` (text, select, checkbox, textarea, ...) |
| Any collection | `<.table>`: density, sticky header, row navigation, selection, grouping, empty state; `overflow="clip"` for one-line rows and hideable columns |
| One value that may not fit | `<.clip>`: ellipsis with the full text in a tooltip |
| Several short tags in a row | `<.chip_list>`: the first chips plus a `+N` popover |
| Page title with actions | `<.header>` |
| A resource's page | `<.object_page>` with tabs, status, and a `<.properties>` aside; `title_action` for the one action the page is for, `notice` for work in progress on the object |
| Lifecycle, freshness, agent, drift | `<.status_strip>` (`row` or `header` size) |
| Editable label/value list | `<.properties>` |
| Switch between a few views | `<.segmented>` |
| Create or edit | `<.side_panel>` |
| Confirm a consequential action | `<.confirm_dialog>` |
| Settings and sign-in pages | `<.settings_page>`, `<.settings_section>`, `<.auth_card>`, `<.divider>` |
| Notifications | `<.flash>` via `Layouts.flash_group` (only in `layouts.ex`) |

Domain modules hold pieces shared within one area: `ElevationComponents`
(rack faces), `TopologyComponents` (link map and line styles),
`PrefixComponents`, `VlanComponents`, `FindingComponents`,
`RequestComponents`, `TriageComponents`, `InventoryComponents`,
`JobComponents` (job states, the collection banner, job activity), and
`CatalogComponents`. Promote a piece to `RengaWeb.UI` once a second area
needs it.

## Phone and tablet

RFD 8 lists the tasks that must be fully usable at 390px; they are covered by
browser tests in `test/renga_web/browser`. Every other screen stays readable:
narrow tables drop columns or scroll inside their own container, tab strips
scroll sideways instead of wrapping, and settings sections stack. Tablets use
the desktop layout with 44px touch targets.

New lists use `<.table overflow="clip">`, which drops low-priority columns
as space runs out (see [Overflow](#overflow)). Older tables still scroll
sideways; move them over when you touch them.

## Accessibility

- Color is never the only signal: pair it with shape, an icon, or text, and add
  `sr-only` labels where the visual is terse (the status strip shows how).
- Mark the current tab, segment, or nav item with `aria-current`.
- Overlays trap focus and close on Escape (handled by the shared components).
- Accent text on accent fills meets WCAG AA in every palette;
  `test/renga_web/components/tokens_test.exs` checks it. Keep it passing when
  changing token values.

## Changing the system

- **A new color token** needs a value in every palette block of `tokens.css`
  (five accents, light and dark, repeated under the system dark-mode media
  query) or, for status, in the three status blocks; then a Tailwind name in
  `app.css`'s `@theme inline`. Document it in the tables above.
- **A new component** goes in `RengaWeb.UI` with a `@doc` and example, styled
  only with tokens, gets a LiveViewTest in `test/renga_web/components`, and
  a sample on the design system page.
  Browser-only behavior (layout, focus, touch targets) gets a Playwright test.
- **The guard** lists screens written before the tokens under `@legacy` with
  their remaining violation counts. Counts may only go down; when you touch a
  legacy screen, move what you touch onto tokens and lower its count. New files
  never join the list. Deliberate exceptions go in `@allowed` with a reason.
- The transitional daisyUI aliases at the end of `app.css`'s `@theme` exist
  only for the legacy screens and are removed once the list is empty.
