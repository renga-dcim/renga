# Releasing Renga

Renga uses a reviewable release-PR flow adapted from `chaba2/textbin`.
Conventional PR titles determine the next semantic version and release notes;
maintainers do not create release tags or GitHub Releases manually.

The Phoenix application and Rust host agent share one release version. The
version in `mix.exs` must always equal the package version in
`agent/Cargo.toml`. Public tags use `vMAJOR.MINOR.PATCH`.

## One-time repository setup

Configure the protections before adding the App secrets. Once both secrets exist,
ordinary pushes to `main` can start preparing release PRs automatically.

1. In the `renga-dcim` organization, go to **Settings → Developer settings →
   GitHub Apps → New GitHub App**. Use a distinct name and the repository URL as
   the homepage. Disable the webhook, choose **Only on this account**, and set
   **Repository permissions → Contents** and **Pull requests** to **Read and write**.
   Leave the other permissions at their defaults (Metadata is read-only).
2. On the App's settings page, choose **Install App → renga-dcim → Only select
   repositories → renga**. Under **General**, note the numeric **App ID** (not the
   Client ID) and choose **Generate a private key**.
3. In the repository's **Settings → Rules → Rulesets**, create active rulesets:

   | Target | Rules | Bypass |
   | --- | --- | --- |
   | `main` branch | Require a pull request and at least one approving review. Dismiss stale approvals when new commits are pushed. Require **Validate title**, **Package release gate**, and **Release image** from GitHub Actions and require the branch to be up to date. Restrict deletions and block force pushes. | None |
   | `release/next` branch | Restrict creations, updates, and deletions; block force pushes. The workflow refreshes this branch with a lease. | Release App only, **Always allow** |
   | Tags matching `v*` (creation ruleset) | Restrict creations. | Release App only, **Always allow** |
   | Tags matching `v*` (immutability ruleset) | Restrict updates and deletions. | None |

   In repository **Settings → General → Pull Requests**, allow only squash
   merging and choose **Pull request title** for the default squash commit title.
   Merge the release PR with its generated title unchanged.
4. In repository **Settings → Environments**, open or create `RELEASE`. Under
   **Deployment branches and tags**, choose **Selected branches and tags**, then
   add branch `main` and tag pattern `v*.*.*`. Under **Environment secrets**, add
   `RELEASE_APP_ID` with the numeric App ID and `RELEASE_APP_PRIVATE_KEY` with the
   full contents of the downloaded PEM, including the header and footer. Enter
   the key directly in GitHub, never in a PR, commit, or chat.

The workflows use an installation token because branch and tag pushes made
with `GITHUB_TOKEN` do not trigger the downstream workflows that tag and
publish the release. The image publisher uses its own job's `GITHUB_TOKEN` with
`packages: write`; the release App does not need registry credentials.

Review pinned action commit SHAs deliberately when upgrading release
dependencies, and verify the git-cliff archive checksum when bumping its version.
A pinned action revision does not authenticate the binaries it downloads.

## Rehearse without releasing

In **Actions → Prepare release PR → Run workflow**, select `main`. With no
existing release tag, expect `chore(release): v0.1.0`. Check the changelog diff
and notes preview, then wait for **Release image** and **Package release gate**
to pass. Confirm both `artifacts-agent-packages-amd64` and
`artifacts-agent-packages-arm64` in the **Release artifacts** run. This rehearsal
creates or refreshes a real PR but does not create a tag, publish a GitHub
Release, or push an image. Leave the PR unmerged until the release is explicitly
approved.

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

The release PR uses cargo-dist to build static-musl archives for x86-64 and
AArch64 on native runners. Repository-owned packaging then creates amd64 and
arm64 Debian packages from those same binaries because cargo-dist does not
model Debian metadata, conffiles, system users, or systemd maintainer scripts.
Both architectures must pass checksum, reproducibility, package-version,
static-linkage, unprivileged dry-run, configuration-permission, and systemd
install/remove/purge checks. A fresh package is deliberately left inactive and
disabled because its endpoint and credentials are placeholders.

Merging the internal release PR creates `vMAJOR.MINOR.PATCH` at its merge
commit after independently validating the PR source, title, and synchronized
versions. The App-authenticated tag push then rebuilds the packages from tagged
source and publishes a GitHub Release containing:

- `renga-agent-x86_64-unknown-linux-musl.tar.gz`
- `renga-agent-aarch64-unknown-linux-musl.tar.gz`
- `renga-agent_MAJOR.MINOR.PATCH_amd64.deb`
- `renga-agent_MAJOR.MINOR.PATCH_arm64.deb`
- per-archive SHA-256 files
- `SHA256SUMS`
- generated Conventional Commit notes and a previous-tag comparison

The same tag also triggers the **docker** workflow. It smoke-tests the tagged
Linux amd64 server image, then publishes it to `ghcr.io/renga-dcim/renga` as
`vMAJOR.MINOR.PATCH`. PRs and ordinary pushes to `main` test the image without
publishing it. After the tag run, copy the digest reference from **Publish
release image** in the run summary and use it for deployments, not the mutable
registry tag:

```text
docker pull ghcr.io/renga-dcim/renga@sha256:<digest>
```

GHCR packages start private. If anonymous downloads are intended, a package
admin must make the linked `renga` package public in **Package settings →
Change visibility** after the first push. Otherwise grant pull access to the
deployment identity. If the package already exists, check **Package settings →
Manage Actions access** and grant `renga-dcim/renga` write access if it does not
inherit access from the repository.

## Local preview

The Nix development shell includes cargo-dist and git-cliff. Preview the
complete changelog or the next version with:

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
