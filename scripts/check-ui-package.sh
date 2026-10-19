#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
source_ref="${RENGA_UI_REF:-$(git -C "$repo_root" rev-parse HEAD)}"
fixture="$repo_root/ui/test/consumer"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/renga-ui-consumer.XXXXXX")"
local_ref=""

cleanup() {
  rm -rf "$work_dir"
  if [[ -n "$local_ref" ]]; then
    git -C "$repo_root" update-ref -d "$local_ref"
  fi
}
trap cleanup EXIT

if [[ -v RENGA_UI_GIT ]]; then
  source_repo="$RENGA_UI_GIT"
else
  source_repo="file://$repo_root"
  local_ref="refs/heads/amp-ui-consumer-check-$$"
  git -C "$repo_root" update-ref "$local_ref" "$source_ref"
fi

cp -R "$fixture/." "$work_dir"
cd "$work_dir"

export RENGA_UI_GIT="$source_repo"
export RENGA_UI_REF="$source_ref"

mix deps.get
mix compile --warnings-as-errors
mix test
mix tailwind.install --if-missing
mix esbuild.install --if-missing
mix tailwind consumer
mix esbuild consumer
node --test assets/js/renga_ui.test.mjs

test -f deps/renga_ui/ui/mix.exs
test ! -f deps/renga_ui/mix.exs
rg --quiet --fixed-strings '.bg-surface' priv/static/app.css
rg --quiet --fixed-strings '.h-row' priv/static/app.css
rg --quiet --fixed-strings '.hero-x-mark' priv/static/app.css
rg --quiet --fixed-strings -- '--hero-x-mark:' priv/static/app.css
rg --quiet --fixed-strings 'phx:close-overlay' priv/static/app.js

printf 'renga_ui sparse consumer passed at %s\n' "$source_ref"
