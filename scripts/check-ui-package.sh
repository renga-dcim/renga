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

# The fixture pins the app's tailwind version, and the binary's name carries
# it, so reuse the app's copy when available. On an empty cache, download with
# curl because GitHub's release redirect exceeds Erlang httpc's header limit.
mkdir -p _build
for binary in "$repo_root"/_build/tailwind-*; do
  if [[ -f "$binary" ]]; then
    cp "$binary" _build/
  fi
done

# shellcheck disable=SC2016 # $version and $target are Tailwind URL placeholders.
IFS=$'\t' read -r tailwind_bin tailwind_url < <(
  mix run --no-start -e '
    version = Tailwind.configured_version()

    url =
      Tailwind.default_base_url()
      |> String.replace("$version", version)
      |> String.replace("$target", Tailwind.configured_target())

    IO.puts([Tailwind.bin_path(version), "\t", url])
  '
)

if [[ ! -x "$tailwind_bin" ]]; then
  mkdir -p "$(dirname "$tailwind_bin")"
  curl --fail --location --retry 3 --retry-all-errors \
    --output "$tailwind_bin" "$tailwind_url"
  chmod +x "$tailwind_bin"
fi

mix esbuild.install --if-missing
mix tailwind consumer
mix esbuild consumer
node --test assets/js/renga_ui.test.mjs

test -f deps/renga_ui/ui/mix.exs
test ! -f deps/renga_ui/mix.exs
grep --quiet --fixed-strings '.bg-surface' priv/static/app.css
grep --quiet --fixed-strings '.h-row' priv/static/app.css
grep --quiet --fixed-strings '.hero-x-mark' priv/static/app.css
grep --quiet --fixed-strings -- '--hero-x-mark:' priv/static/app.css
grep --quiet --fixed-strings 'phx:close-overlay' priv/static/app.js

printf 'renga_ui sparse consumer passed at %s\n' "$source_ref"
