#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rfd_root="${RFD_DIR:-${repo_root}/rfd}"

if [[ -z "${NO_COLOR:-}" && (-t 1 || -n "${FORCE_COLOR:-}") ]]; then
  color_reset=$'\033[0m'
  color_bold=$'\033[1m'
  color_red=$'\033[31m'
  color_green=$'\033[32m'
  color_yellow=$'\033[33m'
  color_blue=$'\033[34m'
  color_dim=$'\033[2m'
else
  color_reset=""
  color_bold=""
  color_red=""
  color_green=""
  color_yellow=""
  color_blue=""
  color_dim=""
fi

if [[ ! -d "${rfd_root}" ]]; then
  printf "%sRFD directory not found:%s %s\n" "${color_red}" "${color_reset}" "${rfd_root}" >&2
  exit 1
fi

colorize_state() {
  local state="$1"
  local padded="$2"

  case "${state}" in
  prediscussion | ideation) printf "%s%s%s" "${color_blue}" "${padded}" "${color_reset}" ;;
  discussion) printf "%s%s%s" "${color_yellow}" "${padded}" "${color_reset}" ;;
  published | committed) printf "%s%s%s" "${color_green}" "${padded}" "${color_reset}" ;;
  abandoned) printf "%s%s%s" "${color_dim}" "${padded}" "${color_reset}" ;;
  *) printf "%s%s%s" "${color_red}" "${padded}" "${color_reset}" ;;
  esac
}

read_rfd() {
  local source="$1"
  local source_name="$2"
  local expected_number="$3"

  awk -v source_name="${source_name}" -v expected_number="${expected_number}" '
    function problem(message) {
      printf "  %s: %s\n", source_name, message > "/dev/stderr"
      errors++
    }

    function clean(value) {
      sub(/^:[^:]+:[[:space:]]*/, "", value)
      if (index(value, "\t") > 0) {
        problem("attribute values must not contain tabs")
        gsub(/\t/, " ", value)
      }
      return value
    }

    BEGIN {
      authors = state = discussion = labels = title = title_number = ""
      title_seen = errors = 0
    }

    !title_seen && $0 ~ /^:authors:[[:space:]]*/ {
      authors_count++
      if (authors_count == 1) authors = clean($0)
      next
    }

    !title_seen && $0 ~ /^:state:[[:space:]]*/ {
      state_count++
      if (state_count == 1) state = clean($0)
      next
    }

    !title_seen && $0 ~ /^:discussion:[[:space:]]*/ {
      discussion_count++
      if (discussion_count == 1) discussion = clean($0)
      next
    }

    !title_seen && $0 ~ /^:labels:[[:space:]]*/ {
      labels_count++
      if (labels_count == 1) labels = clean($0)
      next
    }

    $0 ~ /^= RFD [0-9]+ .+/ {
      title_count++
      if (title_count == 1) {
        value = $0
        sub(/^= RFD /, "", value)
        title_number = value
        sub(/ .*/, "", title_number)
        title = value
        sub(/^[0-9]+ /, "", title)
      }
      title_seen = 1
    }

    END {
      if (authors_count != 1 || authors == "") {
        problem("document must contain exactly one non-empty authors attribute")
      } else if (authors !~ /<[^>]+>/) {
        problem("authors must include a name and address in angle brackets")
      }

      if (state_count != 1 || state == "") {
        problem("document must contain exactly one non-empty state attribute")
      } else if (state !~ /^(prediscussion|ideation|discussion|published|committed|abandoned)$/) {
        problem("invalid state: " state)
      }

      if (discussion_count != 1) {
        problem("document must contain exactly one discussion attribute")
      } else if (discussion != "" && discussion !~ /^https?:\/\//) {
        problem("discussion must be empty or an HTTP(S) URL")
      } else if (state ~ /^(discussion|published|committed)$/ && discussion == "") {
        problem("state " state " requires a discussion URL")
      }

      if (labels_count != 1 || labels == "") {
        problem("document must contain exactly one non-empty labels attribute")
      }

      if (title_count != 1 || title == "") {
        problem("document must contain exactly one RFD title")
      } else if (title_number != expected_number) {
        problem("title number " title_number " does not match directory number " expected_number)
      }

      printf "%s\t%s\t%s\t%d\n", state, title, labels, errors
    }
  ' "${source}"
}

printf "%s%-4s  %-13s  %-42s  %s%s\n" "${color_bold}" "RFD" "State" "Title" "Labels" "${color_reset}"
printf "%s%-4s  %-13s  %-42s  %s%s\n" "${color_dim}" "----" "-------------" "------------------------------------------" "--------------------" "${color_reset}"

failures=0
found=0

shopt -s nullglob
entries=("${rfd_root}"/*)
shopt -u nullglob

for entry in "${entries[@]}"; do
  entry_name="$(basename "${entry}")"

  if [[ "${entry_name}" == "README.md" ]]; then
    continue
  fi

  if [[ ! -d "${entry}" || ! "${entry_name}" =~ ^[0-9]{4}$ ]]; then
    printf "%sinvalid RFD entry%s: %s\n" "${color_red}" "${color_reset}" "${entry_name}" >&2
    failures=$((failures + 1))
    continue
  fi

  found=1
  source="${entry}/README.adoc"

  if [[ ! -f "${source}" ]]; then
    printf "%smissing canonical RFD source%s: %s/README.adoc\n" "${color_red}" "${color_reset}" "${entry_name}" >&2
    failures=$((failures + 1))
    continue
  fi

  number="$(printf '%s\n' "${entry_name}" | sed 's/^0*//')"
  [[ -n "${number}" ]] || number=0

  implementations=()
  [[ -f "${entry}/IMPLEMENTATION.org" ]] && implementations+=("${entry}/IMPLEMENTATION.org")
  [[ -f "${entry}/IMPLEMENTATION.md" ]] && implementations+=("${entry}/IMPLEMENTATION.md")

  if [[ "${#implementations[@]}" -eq 0 ]]; then
    printf "%smissing implementation checklist%s: %s/IMPLEMENTATION.org or IMPLEMENTATION.md\n" "${color_red}" "${color_reset}" "${entry_name}" >&2
    failures=$((failures + 1))
  elif [[ "${#implementations[@]}" -gt 1 ]]; then
    printf "%smultiple implementation checklist formats%s: %s\n" "${color_red}" "${color_reset}" "${entry_name}" >&2
    failures=$((failures + 1))
  else
    implementation="${implementations[0]}"
    implementation_name="$(basename "${implementation}")"

    case "${implementation_name}" in
    IMPLEMENTATION.org)
      expected_heading="#+TITLE: RFD ${entry_name} implementation checklist"
      backlink="[[file:README.adoc]["
      ;;
    IMPLEMENTATION.md)
      expected_heading="# RFD ${entry_name} implementation checklist"
      backlink="](README.adoc)"
      ;;
    esac

    if [[ "$(head -n 1 "${implementation}")" != "${expected_heading}" ]]; then
      printf "%sinvalid implementation checklist heading%s: %s/%s\n" "${color_red}" "${color_reset}" "${entry_name}" "${implementation_name}" >&2
      failures=$((failures + 1))
    fi

    if ! grep -Fq "${backlink}" "${implementation}"; then
      printf "%simplementation checklist must link to its RFD%s: %s/%s\n" "${color_red}" "${color_reset}" "${entry_name}" "${implementation_name}" >&2
      failures=$((failures + 1))
    fi

    if ! grep -Fq "link:${implementation_name}[" "${source}"; then
      printf "%sRFD must link to its implementation checklist%s: %s/README.adoc\n" "${color_red}" "${color_reset}" "${entry_name}" >&2
      failures=$((failures + 1))
    fi
  fi

  if grep -Eq '^\* \[[ xX]\]' "${source}"; then
    printf "%simplementation checkboxes belong in a separate implementation document%s: %s/README.adoc\n" "${color_red}" "${color_reset}" "${entry_name}" >&2
    failures=$((failures + 1))
  fi

  parsed="$(read_rfd "${source}" "${entry_name}/README.adoc" "${number}")"
  state="${parsed%%$'\t'*}"
  remainder="${parsed#*$'\t'}"
  title="${remainder%%$'\t'*}"
  remainder="${remainder#*$'\t'}"
  labels="${remainder%%$'\t'*}"
  parser_errors="${remainder##*$'\t'}"
  failures=$((failures + parser_errors))

  state_field="$(printf '%-13s' "${state:-\(missing\)}")"
  state_text="$(colorize_state "${state}" "${state_field}")"
  printf "%-4s  %s  %-42s  %s\n" "${entry_name}" "${state_text}" "${title:-\(missing title\)}" "${labels:-\(missing labels\)}"
done

if [[ "${found}" -eq 0 ]]; then
  printf "%sno RFDs found%s in %s\n" "${color_red}" "${color_reset}" "${rfd_root}" >&2
  exit 1
fi

if [[ "${failures}" -gt 0 ]]; then
  echo
  printf "%sRFD status check failed%s with %s issue(s).\n" "${color_red}" "${color_reset}" "${failures}" >&2
  exit 1
fi

echo
printf "%sRFD status check passed.%s\n" "${color_green}" "${color_reset}"
