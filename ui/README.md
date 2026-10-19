# renga_ui

Renga's design system as a Mix package: the tokens, their Tailwind names,
the shared function components, and the JS hooks those components need.
Renga depends on it by path. Another Phoenix app can depend on it by git:

```elixir
{:renga_ui, github: "renga-dcim/renga", sparse: "ui", ref: "<commit>"}
```

The guide is [`docs/design-system.md`](../docs/design-system.md). Change
the system here first, then bump the commit in the apps that use it.

## Wiring an app

CSS, after `@import "tailwindcss"` and the heroicons plugin. It brings the
tokens, the `@theme inline` names, the variants, and the `@source` lines for
the components' classes:

```css
@import "../../deps/renga_ui/ui/assets/css/renga_ui.css";
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

`RengaUI.DesignGuard` holds the rules that reject raw colors and off-scale
values; run `RengaUI.DesignGuard.scan/1` over the app's templates in a test.
