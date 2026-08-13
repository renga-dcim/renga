#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output_dir="${1:-${repo_root}/dist}"
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
package_id="$(cargo pkgid -p renga-agent)"
version="${package_id##*@}"

case "${RENGA_AGENT_TARGET:-$(uname -m)}" in
x86_64 | x86_64-unknown-linux-musl)
	rust_target="x86_64-unknown-linux-musl"
	deb_arch="amd64"
	elf_machine="Advanced Micro Devices X86-64"
	;;
aarch64 | arm64 | aarch64-unknown-linux-musl)
	rust_target="aarch64-unknown-linux-musl"
	deb_arch="arm64"
	elf_machine="AArch64"
	;;
*)
	printf 'unsupported agent package target: %s\n' "${RENGA_AGENT_TARGET:-$(uname -m)}" >&2
	exit 1
	;;
esac

archive_name="renga-agent-${rust_target}"
archive="${output_dir}/${archive_name}.tar.gz"
archive_checksum="${archive}.sha256"
deb="${output_dir}/renga-agent_${version}_${deb_arch}.deb"

test -f "${archive}"
test -f "${archive_checksum}"
test -f "${deb}"

(cd "${output_dir}" && sha256sum --check SHA256SUMS)
(cd "${output_dir}" && sha256sum --check "$(basename "${archive_checksum}")")

mkdir -p "${work_dir}/archive"
tar --extract --gzip --file "${archive}" --directory "${work_dir}/archive"
archive_root="$(find "${work_dir}/archive" -mindepth 1 -maxdepth 1 -type d -print -quit)"
test -x "${archive_root}/renga-agent"
test -r "${archive_root}/README.md"
test -r "${archive_root}/CHANGELOG.md"

test "$(dpkg-deb --field "${deb}" Package)" = "renga-agent"
test "$(dpkg-deb --field "${deb}" Architecture)" = "${deb_arch}"
dpkg-deb --extract "${deb}" "${work_dir}/deb"
dpkg-deb --control "${deb}" "${work_dir}/control"
test -x "${work_dir}/deb/usr/bin/renga-agent"
test -r "${work_dir}/deb/etc/renga/agent.toml"
test -r "${work_dir}/deb/lib/systemd/system/renga-agent.service"
if readelf --program-headers "${work_dir}/deb/usr/bin/renga-agent" | grep -q 'INTERP'; then
	printf 'Debian package binary is not statically linked\n' >&2
	exit 1
fi
if readelf --dynamic "${work_dir}/deb/usr/bin/renga-agent" 2>/dev/null | grep -q 'NEEDED'; then
	printf 'Debian package binary requires shared libraries\n' >&2
	exit 1
fi
readelf --file-header "${work_dir}/deb/usr/bin/renga-agent" |
	grep -q "Machine:.*${elf_machine}"
sh -n "${work_dir}/control/postinst"
sh -n "${work_dir}/control/prerm"
sh -n "${work_dir}/control/postrm"
grep -q 'StateDirectory=renga' "${work_dir}/deb/lib/systemd/system/renga-agent.service"
grep -q 'StateDirectoryMode=0700' "${work_dir}/deb/lib/systemd/system/renga-agent.service"
grep -q 'install -d -o renga-agent -g renga-agent -m 0700 /var/lib/renga' \
	"${work_dir}/control/postinst"
if grep -Eq 'rm .*/var/lib/renga|rm -r.*/var/lib/renga' "${work_dir}/control/postinst" "${work_dir}/control/postrm"; then
	printf 'Debian maintainer scripts must preserve installation identity state\n' >&2
	exit 1
fi

"${archive_root}/renga-agent" --version
"${archive_root}/renga-agent" --dry-run >"${work_dir}/observation.json"
python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as observation_file:
    observation = json.load(observation_file)

assert observation["resources"][0]["kind"] == "server"
assert observation["observation_id"]
' "${work_dir}/observation.json"

printf 'Verified package structure, checksums, maintainer scripts, and dry-run observation.\n'
