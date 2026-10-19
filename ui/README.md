# renga_ui

Renga's design system as a Mix package: the tokens, their Tailwind names,
the shared function components, and the JS hooks those components need.
Renga depends on it by path. Another Phoenix app can depend on it by git:

```elixir
{:renga_ui, github: "renga-dcim/renga", sparse: "ui", ref: "<commit>"}
```

The [design-system guide](https://github.com/renga-dcim/renga/blob/main/docs/design-system.md)
defines the shared visual language. Change the system here first, then bump the
commit in the apps that use it.

## Wiring an app

The package expects Tailwind CSS 4 and the Phoenix-generated Heroicons plugin.
Keep `assets/vendor/heroicons.js` in the host app and its Mix dependency:

```elixir
{:heroicons,
 github: "tailwindlabs/heroicons",
 tag: "v2.2.0",
 sparse: "optimized",
 app: false,
 compile: false,
 depth: 1}
```

Import the host's Heroicons plugin before `renga_ui.css`. The package stylesheet
brings the tokens, `@theme inline` names, variants, and `@source` lines for the
components' classes:

```css
@import "tailwindcss" source(none);
@plugin "../vendor/heroicons";
@import "../../deps/renga_ui/ui/assets/css/renga_ui.css";
```

The stylesheet loads IBM Plex Sans and IBM Plex Mono from `/fonts`. Serve the
package's bundled files there from the endpoint, next to the app's own
`Plug.Static`:

```elixir
plug Plug.Static,
  at: "/",
  from: {:renga_ui, "priv/static"},
  only: ~w(fonts)
```

JS, with an esbuild alias such as `--alias:renga_ui=../deps/renga_ui/ui/assets/js`:

```js
import {hooks as uiHooks, install as installUI} from "renga_ui"

const liveSocket = new LiveSocket("/live", Socket, {hooks: {...uiHooks}})
installUI()
```

Elixir, in the app's `html_helpers`:

```elixir
import RengaUI.CoreComponents
import RengaUI.Components
```

Component-owned strings and validation errors use `RengaUI.Gettext`. Set its
locale separately from the host backend and put shared translations in the
package's `errors` domain.

`RengaUI.DesignGuard` holds the rules that reject raw colors and off-scale
values; run `RengaUI.DesignGuard.scan/1` over the app's templates in a test.

Run `make check-ui-package` in the Renga repository to install the current
commit through the documented sparse Git dependency and smoke-test this wiring.
