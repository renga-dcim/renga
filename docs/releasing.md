# Releasing Renga

Renga uses a reviewable release-PR flow adapted from `chaba2/textbin`.
Conventional PR titles determine the next semantic version and release notes;
maintainers do not create release tags or GitHub Releases manually.

The Phoenix application and Rust host agent share one release version. The
version in `mix.exs` must always equal the package version in
`agent/Cargo.toml`. Public tags use `vMAJOR.MINOR.PATCH`.

## One-time repository setup

Create and install a GitHub App for this repository with these repository
permissions:

- Contents: read and write
- Pull requests: read and write

Create a GitHub Actions environment named `RELEASE`, then store the App
credentials as environment secrets:

```text
RELEASE_APP_ID
RELEASE_APP_PRIVATE_KEY
```

The workflows use an installation token because branch and tag pushes made
with `GITHUB_TOKEN` do not trigger the downstream workflows that tag and
publish the release.

Protect `main`, require pull requests, allow only squash merges, and configure
the squash commit subject to use the PR title. Require branches to be current
with `main` before merging, disallow ruleset bypasses for release PRs, and
require the stable **Validate title** check so the resulting `main` commit is a
Conventional Commit.

Protect `release/next` so only the release App can force-push it. Refresh a
stale release PR by running **Prepare release PR** rather than editing that
automation-owned branch. Protect `v*` tags as immutable and allow only the
release App to create them.

Require the stable **Package release gate** check on `main`. Review pinned
action commit SHAs deliberately when upgrading release dependencies; the SHA,
not its version comment, is the security boundary.

## Automated flow

Every ordinary push to `main` refreshes one PR from `release/next`:

1. Find the latest reachable `v*` tag and commits since that tag.
2. Ask git-cliff to choose the next version from Conventional Commits.
3. Synchronize `mix.exs` and `agent/Cargo.toml`.
4. Regenerate `CHANGELOG.md` and the release-notes preview.
5. Force-update `release/next` with lease protection.
6. Create or update the release PR.

Before the first tag, automation uses the synchronized version already checked
into the manifests. Afterward, git-cliff calculates the next stable semantic
version. Review the generated version, changelog, notes, and comparison. Do not
manually edit `release/next`; the next preparation run replaces it.

The release PR builds the static x86-64 Linux agent, tarball, and Debian
package. It verifies checksums, reproducibility, package versions, static ELF
linkage, unprivileged dry-run collection, configuration permissions, and the
systemd install/remove/purge lifecycle. A fresh package is deliberately left
inactive and disabled because its endpoint and credentials are placeholders.

Merging the internal release PR creates `vMAJOR.MINOR.PATCH` at its merge
commit after independently validating the PR source, title, and synchronized
versions. The App-authenticated tag push then rebuilds the packages from tagged
source and publishes a GitHub Release containing:

- `renga-agent-MAJOR.MINOR.PATCH-linux-x86_64.tar.gz`
- `renga-agent_MAJOR.MINOR.PATCH_amd64.deb`
- `SHA256SUMS`
- generated Conventional Commit notes and a previous-tag comparison

```text
main changes
    -> release/next PR
    -> vMAJOR.MINOR.PATCH tag
    -> GitHub Release with agent packages, checksums, and notes
```

## Local preview

The Nix development shell includes git-cliff. Preview the complete changelog or
the next version with:

```bash
make changelog
git cliff --bumped-version
```

`make changelog` rewrites `CHANGELOG.md`; restore it if the preview was not
intended as a release change. Build and verify the exact release packages with:

```bash
make agent-packages
make verify-agent-packages
```
