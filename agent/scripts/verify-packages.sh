#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output_dir="${1:-${repo_root}/dist}"
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
package_id="$(cargo pkgid -p renga-agent)"
version="${package_id##*@}"
archive="${output_dir}/renga-agent-${version}-linux-x86_64.tar.gz"
deb="${output_dir}/renga-agent_${version}_amd64.deb"

test -f "${archive}"
test -f "${deb}"

(cd "${output_dir}" && sha256sum --check SHA256SUMS)

mkdir -p "${work_dir}/archive"
tar --extract --gzip --file "${archive}" --directory "${work_dir}/archive"
archive_root="$(find "${work_dir}/archive" -mindepth 1 -maxdepth 1 -type d -print -quit)"
test -x "${archive_root}/usr/bin/renga-agent"
test -r "${archive_root}/etc/renga/agent.toml.example"
test -r "${archive_root}/lib/systemd/system/renga-agent.service"

test "$(dpkg-deb --field "${deb}" Package)" = "renga-agent"
test "$(dpkg-deb --field "${deb}" Architecture)" = "amd64"
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
	grep -q 'Machine:.*Advanced Micro Devices X86-64'
sh -n "${work_dir}/control/postinst"
sh -n "${work_dir}/control/prerm"
sh -n "${work_dir}/control/postrm"

"${archive_root}/usr/bin/renga-agent" --version
"${archive_root}/usr/bin/renga-agent" --dry-run >"${work_dir}/observation.json"
python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as observation_file:
    observation = json.load(observation_file)

assert observation["resources"][0]["kind"] == "server"
assert observation["observation_id"]
' "${work_dir}/observation.json"

printf 'Verified package structure, checksums, maintainer scripts, and dry-run observation.\n'
