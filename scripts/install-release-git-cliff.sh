#!/usr/bin/env bash
set -euo pipefail

# Release jobs later receive an App key. Verify the immutable archive bytes,
# not just the version in the upstream release URL, before installing code.
version=2.14.2
target=x86_64-unknown-linux-gnu
archive="git-cliff-${version}-${target}"
sha256=24f397c733add5390fdceee3a2088588ab0d5f944ce00d34cb7029b888cf2db4

install_dir=$(mktemp -d "$RUNNER_TEMP/renga-git-cliff.XXXXXX")
cd "$install_dir"
curl --proto '=https' --tlsv1.2 -fLsS \
  "https://github.com/orhun/git-cliff/releases/download/v${version}/${archive}.tar.gz" \
  -o git-cliff.tar.gz
printf '%s  git-cliff.tar.gz\n' "$sha256" | sha256sum --check --strict
tar -xzf git-cliff.tar.gz --strip-components=1 "git-cliff-${version}/git-cliff"
printf '%s\n' "$install_dir" >> "$GITHUB_PATH"
