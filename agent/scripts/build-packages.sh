#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output_dir="${1:-${repo_root}/dist}"
cargo metadata --manifest-path "${repo_root}/Cargo.toml" --locked --format-version 1 >/dev/null
package_id="$(cargo pkgid -p renga-agent)"
version="${package_id##*@}"

case "${RENGA_AGENT_TARGET:-$(uname -m)}" in
x86_64 | x86_64-unknown-linux-musl)
	deb_arch="amd64"
	rust_target="x86_64-unknown-linux-musl"
	;;
aarch64 | arm64 | aarch64-unknown-linux-musl)
	deb_arch="arm64"
	rust_target="aarch64-unknown-linux-musl"
	;;
*)
	printf 'unsupported agent package target: %s\n' "${RENGA_AGENT_TARGET:-$(uname -m)}" >&2
	exit 1
	;;
esac

if [[ "$(uname -s)" != "Linux" ]]; then
	printf 'agent Linux packages must be built on Linux\n' >&2
	exit 1
fi

for command in cargo dist dpkg-deb readelf sha256sum tar; do
	if ! command -v "${command}" >/dev/null 2>&1; then
		printf 'required packaging command not found: %s\n' "${command}" >&2
		exit 1
	fi
done

source_date_epoch="${SOURCE_DATE_EPOCH:-$(git -C "${repo_root}" log -1 --format=%ct 2>/dev/null || date +%s)}"
export SOURCE_DATE_EPOCH="${source_date_epoch}"
archive_name="renga-agent-${rust_target}"
deb_name="renga-agent_${version}_${deb_arch}"
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

mkdir -p "${output_dir}"
rm -f \
	"${output_dir}/${archive_name}.tar.gz" \
	"${output_dir}/${archive_name}.tar.gz.sha256" \
	"${output_dir}/${deb_name}.deb" \
	"${output_dir}/SHA256SUMS"

printf 'Building renga-agent %s for %s...\n' "${version}" "${rust_target}"
dist build --artifacts=local --target "${rust_target}" --tag "v${version}"
binary="${repo_root}/target/${rust_target}/dist/renga-agent"
if readelf --program-headers "${binary}" | grep -q 'INTERP'; then
	printf 'packaged agent binary must be statically linked\n' >&2
	exit 1
fi
if readelf --dynamic "${binary}" 2>/dev/null | grep -q 'NEEDED'; then
	printf 'packaged agent binary must not require shared libraries\n' >&2
	exit 1
fi

dist_archive="${repo_root}/target/distrib/${archive_name}.tar.gz"
mkdir -p "${work_dir}/cargo-dist"
tar --extract --gzip --file "${dist_archive}" --directory "${work_dir}/cargo-dist"
tar \
	--create \
	--gzip \
	--file "${work_dir}/${archive_name}.tar.gz" \
	--directory "${work_dir}/cargo-dist" \
	--sort=name \
	--mtime="@${source_date_epoch}" \
	--owner=0 \
	--group=0 \
	--numeric-owner \
	"${archive_name}"
sha256sum "${work_dir}/${archive_name}.tar.gz" |
	sed 's#  .*/# *#' >"${work_dir}/${archive_name}.tar.gz.sha256"

install -m 0644 "${work_dir}/${archive_name}.tar.gz" \
	"${output_dir}/${archive_name}.tar.gz"
install -m 0644 "${work_dir}/${archive_name}.tar.gz.sha256" \
	"${output_dir}/${archive_name}.tar.gz.sha256"

deb_root="${work_dir}/${deb_name}"
install -D -m 0755 "${binary}" \
	"${deb_root}/usr/bin/renga-agent"
install -D -m 0644 "${repo_root}/agent/dist/renga-agent.service" \
	"${deb_root}/lib/systemd/system/renga-agent.service"
install -D -m 0640 "${repo_root}/agent/dist/agent.toml.example" \
	"${deb_root}/etc/renga/agent.toml"
install -D -m 0644 "${repo_root}/agent/README.md" \
	"${deb_root}/usr/share/doc/renga-agent/README.md"
mkdir -p "${deb_root}/DEBIAN"

installed_size="$(du --apparent-size -sk "${deb_root}" | cut -f1)"
cat >"${deb_root}/DEBIAN/control" <<EOF
Package: renga-agent
Version: ${version}
Section: admin
Priority: optional
Architecture: ${deb_arch}
Installed-Size: ${installed_size}
Maintainer: Renga DCIM <renga-dcim@users.noreply.github.com>
Depends: adduser, init-system-helpers, systemd
Description: Renga host inventory agent
 Collects Linux host inventory and reports observations and lease check-ins to
 a Renga DCIM server.
EOF

cat >"${deb_root}/DEBIAN/conffiles" <<'EOF'
/etc/renga/agent.toml
EOF

cat >"${deb_root}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

if ! getent group renga-agent >/dev/null; then
    addgroup --system renga-agent
fi
if ! getent passwd renga-agent >/dev/null; then
    adduser --system --ingroup renga-agent --home /nonexistent \
        --no-create-home --shell /usr/sbin/nologin renga-agent
fi

install -d -o root -g renga-agent -m 0750 /etc/renga
install -d -o renga-agent -g renga-agent -m 0700 /var/lib/renga
if [ -f /etc/renga/agent.toml ]; then
    chown root:renga-agent /etc/renga/agent.toml
    chmod 0640 /etc/renga/agent.toml
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

if deb-systemd-helper debian-installed renga-agent.service; then
	deb-systemd-helper unmask renga-agent.service >/dev/null || true
	if deb-systemd-helper --quiet was-enabled renga-agent.service; then
		deb-systemd-helper enable renga-agent.service >/dev/null || true
	fi
fi
deb-systemd-helper update-state renga-agent.service >/dev/null || true

# Restart an already-running service after upgrades without starting a fresh or
# deliberately stopped installation.
if [ -n "${2:-}" ] && command -v deb-systemd-invoke >/dev/null 2>&1; then
	deb-systemd-invoke try-restart renga-agent.service >/dev/null || true
fi

exit 0
EOF
chmod 0755 "${deb_root}/DEBIAN/postinst"

cat >"${deb_root}/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = remove ] && command -v deb-systemd-invoke >/dev/null 2>&1; then
    deb-systemd-invoke stop renga-agent.service >/dev/null || true
fi

exit 0
EOF
chmod 0755 "${deb_root}/DEBIAN/prerm"

cat >"${deb_root}/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = remove ] && command -v deb-systemd-helper >/dev/null 2>&1; then
	deb-systemd-helper mask renga-agent.service >/dev/null || true
fi

if [ "$1" = purge ] && command -v deb-systemd-helper >/dev/null 2>&1; then
	deb-systemd-helper purge renga-agent.service >/dev/null || true
	deb-systemd-helper unmask renga-agent.service >/dev/null || true
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

exit 0
EOF
chmod 0755 "${deb_root}/DEBIAN/postrm"

find "${deb_root}" -print0 | xargs -0 touch --date="@${source_date_epoch}"
dpkg-deb --root-owner-group --build "${deb_root}" "${output_dir}/${deb_name}.deb" >/dev/null

(
	cd "${output_dir}"
	sha256sum "${archive_name}.tar.gz" "${deb_name}.deb" >SHA256SUMS
)

printf 'Built:\n  %s\n  %s\n  %s\n  %s\n' \
	"${output_dir}/${archive_name}.tar.gz" \
	"${output_dir}/${archive_name}.tar.gz.sha256" \
	"${output_dir}/${deb_name}.deb" \
	"${output_dir}/SHA256SUMS"
