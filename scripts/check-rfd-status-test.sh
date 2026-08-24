#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="${repo_root}/scripts/check-rfd-status.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/renga-rfd-check.XXXXXX")"
rfd_root="${test_root}/rfd"
base_rfd_root="${test_root}/base-rfd"
output="${test_root}/output"

trap 'rm -rf "${test_root}"' EXIT

reset_fixtures() {
  unset RFD_BASE_DIR
  rm -rf "${rfd_root}" "${base_rfd_root}"
  mkdir -p "${rfd_root}"
  printf '# Test RFDs\n' >"${rfd_root}/README.md"
}

run_success() {
  if ! NO_COLOR=1 RFD_DIR="${rfd_root}" bash "${checker}" >"${output}" 2>&1; then
    cat "${output}" >&2
    printf 'expected RFD checker to pass\n' >&2
    exit 1
  fi
}

run_failure() {
  local expected="$1"

  if NO_COLOR=1 RFD_DIR="${rfd_root}" bash "${checker}" >"${output}" 2>&1; then
    cat "${output}" >&2
    printf 'expected RFD checker to fail with: %s\n' "${expected}" >&2
    exit 1
  fi

  if ! grep -Fq "${expected}" "${output}"; then
    cat "${output}" >&2
    printf 'RFD checker failure did not include: %s\n' "${expected}" >&2
    exit 1
  fi
}

write_valid_rfd() {
  local state="$1"
  local discussion="$2"
  local implementation_format="${3:-org}"
  local implementation_name

  case "${implementation_format}" in
  org) implementation_name="IMPLEMENTATION.org" ;;
  md) implementation_name="IMPLEMENTATION.md" ;;
  *)
    printf 'unsupported test implementation format: %s\n' "${implementation_format}" >&2
    exit 1
    ;;
  esac

  mkdir -p "${rfd_root}/0001"
  cat >"${rfd_root}/0001/README.adoc" <<EOF
:authors: Example Author <author@example.com>
:state: ${state}
:discussion: ${discussion}
:labels: software, process

= RFD 1 Valid RFD

== Implementation

See link:${implementation_name}[implementation checklist].
EOF

  case "${implementation_format}" in
  org)
    cat >"${rfd_root}/0001/${implementation_name}" <<'EOF'
#+TITLE: RFD 0001 implementation checklist

Implements [[file:README.adoc][RFD 1: Valid RFD]].

- [ ] Complete the work.
EOF
    ;;
  md)
    cat >"${rfd_root}/0001/${implementation_name}" <<'EOF'
# RFD 0001 implementation checklist

Implements [RFD 1: Valid RFD](README.adoc).

- [ ] Complete the work.
EOF
    ;;
  esac
}

reset_fixtures
write_valid_rfd discussion https://example.com/pull/1
run_success

reset_fixtures
write_valid_rfd prediscussion "" md
run_success

reset_fixtures
write_valid_rfd prediscussion ""
rm "${rfd_root}/0001/IMPLEMENTATION.org"
run_failure "missing implementation checklist"

reset_fixtures
write_valid_rfd prediscussion ""
printf '\n  - [ ] This belongs in the implementation document.\n' >>"${rfd_root}/0001/README.adoc"
run_failure "implementation checkboxes belong in a separate implementation document"

reset_fixtures
write_valid_rfd prediscussion ""
printf '\n+ [ ] This also belongs in the implementation document.\n' >>"${rfd_root}/0001/README.adoc"
run_failure "implementation checkboxes belong in a separate implementation document"

reset_fixtures
write_valid_rfd prediscussion ""
printf '\n1. [X] This also belongs in the implementation document.\n' >>"${rfd_root}/0001/README.adoc"
run_failure "implementation checkboxes belong in a separate implementation document"

reset_fixtures
write_valid_rfd committed https://example.com/pull/1
run_failure "committed RFD has incomplete implementation tasks"

reset_fixtures
write_valid_rfd committed https://example.com/pull/1
sed -i.bak '/Complete the work/d' "${rfd_root}/0001/IMPLEMENTATION.org"
rm "${rfd_root}/0001/IMPLEMENTATION.org.bak"
run_failure "committed RFD requires a non-empty implementation checklist"

reset_fixtures
write_valid_rfd committed https://example.com/pull/1
sed -i.bak 's/- \[ \]/- [X]/' "${rfd_root}/0001/IMPLEMENTATION.org"
rm "${rfd_root}/0001/IMPLEMENTATION.org.bak"
run_success

reset_fixtures
write_valid_rfd prediscussion ""
printf '# RFD 0001 implementation checklist\n\nImplements [RFD 1](README.adoc).\n' >"${rfd_root}/0001/IMPLEMENTATION.md"
run_failure "multiple implementation checklist formats"

reset_fixtures
write_valid_rfd draft ""
run_failure "invalid state: draft"

reset_fixtures
write_valid_rfd discussion ""
run_failure "state discussion requires a discussion URL"

reset_fixtures
write_valid_rfd prediscussion ""
sed -i.bak '1a\
:authors: Another Author <another@example.com>
' "${rfd_root}/0001/README.adoc"
rm "${rfd_root}/0001/README.adoc.bak"
run_failure "exactly one non-empty authors attribute"

reset_fixtures
write_valid_rfd prediscussion ""
sed -i.bak 's/= RFD 1 /= RFD 2 /' "${rfd_root}/0001/README.adoc"
rm "${rfd_root}/0001/README.adoc.bak"
run_failure "does not match directory number 1"

reset_fixtures
mkdir -p "${rfd_root}/1"
printf '= RFD 1 Invalid directory\n' >"${rfd_root}/1/README.adoc"
run_failure "invalid RFD entry"

reset_fixtures
mkdir -p "${rfd_root}/.draft"
run_failure "invalid RFD entry"

reset_fixtures
write_valid_rfd discussion https://example.com/pull/2
mkdir -p "${base_rfd_root}"
cp -R "${rfd_root}/0001" "${base_rfd_root}/0001"
sed -i.bak 's/:state: discussion/:state: published/' "${base_rfd_root}/0001/README.adoc"
rm "${base_rfd_root}/0001/README.adoc.bak"
export RFD_BASE_DIR="${base_rfd_root}"
run_failure "invalid RFD state transition"

reset_fixtures
write_valid_rfd published https://example.com/pull/2
mkdir -p "${base_rfd_root}"
cp -R "${rfd_root}/0001" "${base_rfd_root}/0001"
sed -i.bak 's/:state: published/:state: discussion/' "${base_rfd_root}/0001/README.adoc"
rm "${base_rfd_root}/0001/README.adoc.bak"
export RFD_BASE_DIR="${base_rfd_root}"
run_success

printf 'RFD checker tests passed.\n'
