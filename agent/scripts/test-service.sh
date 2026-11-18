#!/usr/bin/env bash
# Runs the shipped systemd unit against a loopback stub server and checks that the
# SMBIOS pre-start helper never stops the agent from starting and checking in:
# missing source files, a failing helper, and a helper that ignores TERM past its
# deadline. A last run uses the real helper and checks the sandboxed agent reports
# the DMI UUID only root can read. Needs root on a disposable systemd host such as
# a CI runner; it installs and removes the unit, user, and binary.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
binary="${1:-${repo_root}/target/debug/renga-agent}"
unit=renga-agent.service
dropin_dir="/run/systemd/system/${unit}.d"
work_dir="$(mktemp -d)"
port=18089
requests="${work_dir}/requests"
observation="${work_dir}/observation.json"

if [[ "$(id -u)" != 0 ]]; then
	printf 'test-service.sh must run as root\n' >&2
	exit 1
fi

cleanup() {
	systemctl stop "${unit}" >/dev/null 2>&1 || true
	rm -rf "${dropin_dir}" "/etc/systemd/system/${unit}" /etc/renga /run/renga /var/lib/renga
	systemctl daemon-reload || true
	if [[ -n "${stub_pid:-}" ]]; then
		kill "${stub_pid}" 2>/dev/null || true
		wait "${stub_pid}" 2>/dev/null || true
	fi
	rm -rf "${work_dir}"
}
trap cleanup EXIT

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	journalctl --unit "${unit}" --no-pager --lines 40 >&2 || true
	exit 1
}

install -m 0755 "${binary}" /usr/bin/renga-agent
getent group renga-agent >/dev/null || groupadd --system renga-agent
getent passwd renga-agent >/dev/null ||
	useradd --system --gid renga-agent --home-dir /nonexistent --no-create-home \
		--shell /usr/sbin/nologin renga-agent
install -m 0644 "${repo_root}/agent/dist/${unit}" "/etc/systemd/system/${unit}"
install -d -o root -g renga-agent -m 0750 /etc/renga
cat >"${work_dir}/agent.toml" <<EOF
renga_url = "http://127.0.0.1:${port}"
allow_insecure_http = true
intake_api_key = "service-test-key"
max_retry_attempts = 1
EOF
install -o root -g renga-agent -m 0640 "${work_dir}/agent.toml" /etc/renga/agent.toml

cat >"${work_dir}/stub.py" <<'EOF'
from datetime import datetime, timezone
import http.server
import json
import sys
import uuid

port, requests, observation = int(sys.argv[1]), sys.argv[2], sys.argv[3]
source_id = str(uuid.uuid4())
receipts = {}


class Handler(http.server.BaseHTTPRequestHandler):
    # A deployment is its own home (RFD 23).
    def do_GET(self):
        if not self.path.startswith("/api/v1/agent/home?"):
            self.send_error(404)
            return
        body = json.dumps({"home": f"http://127.0.0.1:{port}"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(requests, "a", encoding="utf-8") as file:
            file.write(self.path + "\n")
        if self.path != "/api/v1/observations":
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        submitted = json.loads(body)
        key = submitted["observation_id"]
        duplicate = key in receipts
        if duplicate:
            original, accepted = receipts[key]
            if body != original:
                self.send_error(409)
                return
        else:
            accepted = {
                "status": "accepted",
                "receipt": {
                    "id": str(uuid.uuid4()),
                    "position": len(receipts) + 1,
                    "accepted_at": datetime.now(timezone.utc).isoformat(),
                },
                "processing": {"status": "pending"},
                "observation": {
                    "id": str(uuid.uuid4()),
                    "observation_id": key,
                    "observed_at": submitted["observed_at"],
                    "source_id": source_id,
                },
            }
            with open(observation, "wb") as file:
                file.write(body)
            receipts[key] = (body, accepted)
        response = json.dumps(dict(accepted, duplicate=duplicate)).encode()
        self.send_response(200 if duplicate else 202)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, *args):
        pass


# Serialize receipt allocation and replay, like the intake's unique acceptance.
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
EOF
python3 "${work_dir}/stub.py" "${port}" "${requests}" "${observation}" &
stub_pid=$!

# Replaces the unit's pre-start step; an empty value keeps the shipped one.
use_prestart() {
	rm -rf "${dropin_dir}"
	if [[ -n "$1" ]]; then
		mkdir -p "${dropin_dir}"
		printf '[Service]\nExecStartPre=\nExecStartPre=%s\n' "$1" >"${dropin_dir}/test.conf"
	fi
	systemctl daemon-reload
}

# Starts the unit and waits for a check-in and acknowledged delivery; prints start seconds.
start_and_check_in() {
	local name="$1" started elapsed invocation
	systemctl stop "${unit}" >/dev/null 2>&1 || true
	rm -f "${requests}" "${observation}"
	started=$(date +%s)
	systemctl start "${unit}" || fail "${name}: unit did not start"
	elapsed=$(($(date +%s) - started))
	invocation=$(systemctl show -p InvocationID --value "${unit}")
	# A POST on its own isn't proof of delivery. Stopping before the agent drains
	# its queue can replay this phase's observation during the next phase.
	for _ in $(seq 60); do
		if grep -qx /api/v1/agent/checkins "${requests}" 2>/dev/null &&
			[[ -s "${observation}" ]] &&
			journalctl --quiet --lines=1 --grep='"message":"observation posted"' \
				"_SYSTEMD_INVOCATION_ID=${invocation}" >/dev/null; then
			test "$(systemctl show -p ActiveState --value "${unit}")" = active ||
				fail "${name}: unit is not active"
			printf '%s: started in %ss, checked in and delivered an observation\n' "${name}" "${elapsed}"
			STARTED_IN="${elapsed}"
			return
		fi
		sleep 0.5
	done
	fail "${name}: agent did not check in and deliver an observation"
}

no_snapshot() {
	test ! -e /run/renga/smbios/current || fail "$1: a snapshot was published"
}

shipped_helper='/usr/bin/timeout --kill-after=1s 5s /usr/bin/renga-agent snapshot-smbios'

# Missing source files: the real helper, with the firmware directory hidden.
rm -rf /run/renga
use_prestart "-+/usr/bin/unshare --mount --propagation private /bin/sh -c 'mount -t tmpfs tmpfs /sys/firmware && exec ${shipped_helper}'"
start_and_check_in "missing source files"
no_snapshot "missing source files"

# A helper that exits nonzero.
use_prestart "-+/bin/false"
start_and_check_in "nonzero exit"
no_snapshot "nonzero exit"

# A helper that hangs and ignores TERM, so only the KILL after the grace period ends it.
use_prestart "-+/usr/bin/timeout --kill-after=1s 5s /bin/sh -c 'trap \"\" TERM; exec sleep 3127'"
start_and_check_in "hanging helper"
no_snapshot "hanging helper"
((STARTED_IN >= 5 && STARTED_IN <= 15)) ||
	fail "hanging helper: start took ${STARTED_IN}s, expected the 5s deadline plus grace"
if pgrep -fx 'sleep 3127' >/dev/null; then
	fail "hanging helper: the helper was not reaped"
fi

# The shipped unit: the helper publishes and the sandboxed agent reads it.
use_prestart ""
grep -qx "ExecStartPre=-+${shipped_helper}" "/etc/systemd/system/${unit}" ||
	fail "shipped unit: unexpected pre-start step"
start_and_check_in "shipped helper"
if [[ -r /sys/firmware/dmi/tables/DMI ]]; then
	test -L /run/renga/smbios/current || fail "shipped helper: no snapshot was published"
	generation="/run/renga/smbios/$(readlink /run/renga/smbios/current)"
	test "$(stat --format=%U:%G:%a "${generation}/DMI")" = root:renga-agent:440 ||
		fail "shipped helper: snapshot has the wrong ownership or mode"
	test "$(stat --format=%U:%a /run/renga/smbios)" = root:755 ||
		fail "shipped helper: destination is not root-owned"
	if expected=$(tr '[:upper:]' '[:lower:]' </sys/class/dmi/id/product_uuid 2>/dev/null); then
		python3 - "${observation}" "${expected}" <<'EOF' || fail "shipped helper: DMI UUID not reported"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    reported = json.load(file)["resources"][0]["identifiers"].get("dmi_uuid")
assert reported == sys.argv[2], (reported, sys.argv[2])
print(f"shipped helper: agent reported DMI UUID {reported} from the snapshot")
EOF
	fi
else
	printf 'shipped helper: host has no SMBIOS tables; skipped snapshot checks\n'
fi

printf 'Service tests passed.\n'
