#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rfd_root="${RFD_DIR:-${repo_root}/rfd}"
base_ref="${RFD_BASE_REF:-}"
base_rfd_root="${RFD_BASE_DIR:-}"

# GitHub uses an all-zero before SHA when a branch has no prior revision.
[[ "${base_ref}" =~ ^0+$ ]] && base_ref=""

if [[ -n "${base_ref}" && -n "${base_rfd_root}" ]]; then
  printf "RFD_BASE_REF and RFD_BASE_DIR are mutually exclusive\n" >&2
  exit 1
fi

if [[ -n "${base_ref}" ]] && ! git -C "${repo_root}" cat-file -e "${base_ref}^{commit}" 2>/dev/null; then
  printf "cannot resolve RFD base revision: %s\n" "${base_ref}" >&2
  exit 1
fi

if [[ -n "${base_rfd_root}" && ! -d "${base_rfd_root}" ]]; then
  printf "RFD base directory not found: %s\n" "${base_rfd_root}" >&2
  exit 1
fi

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

colorize_progress() {
  local complete="$1"
  local total="$2"
  local padded="$3"

  if [[ "${total}" -eq 0 || "${complete}" -eq 0 ]]; then
    printf "%s%s%s" "${color_dim}" "${padded}" "${color_reset}"
  elif [[ "${complete}" -eq "${total}" ]]; then
    printf "%s%s%s" "${color_green}" "${padded}" "${color_reset}"
  else
    printf "%s%s%s" "${color_yellow}" "${padded}" "${color_reset}"
  fi
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

read_state() {
  awk '
    /^= RFD [0-9]+ .+/ { exit }
    /^:state:[[:space:]]*/ {
      sub(/^:state:[[:space:]]*/, "")
      print
      exit
    }
  '
}

read_base_state() {
  local entry_name="$1"
  local base_source

  if [[ -n "${base_rfd_root}" ]]; then
    base_source="${base_rfd_root}/${entry_name}/README.adoc"
    [[ -f "${base_source}" ]] && read_state <"${base_source}"
    return
  fi

  if [[ -n "${base_ref}" ]]; then
    git -C "${repo_root}" show "${base_ref}:rfd/${entry_name}/README.adoc" 2>/dev/null |
      read_state || true
  fi
}

list_base_entry_names() {
  local base_entry

  if [[ -n "${base_rfd_root}" ]]; then
    shopt -s nullglob dotglob
    for base_entry in "${base_rfd_root}"/*; do
      basename "${base_entry}"
    done
    shopt -u nullglob dotglob
    return
  fi

  if [[ -n "${base_ref}" ]] && git -C "${repo_root}" cat-file -e "${base_ref}:rfd" 2>/dev/null; then
    git -C "${repo_root}" ls-tree --name-only "${base_ref}:rfd"
  fi
}

rfd_changed_from_base() {
  local entry_name="$1"

  if [[ -n "${base_rfd_root}" ]]; then
    if diff -qr "${base_rfd_root}/${entry_name}" "${rfd_root}/${entry_name}" >/dev/null 2>&1; then
      return 1
    fi
    return 0
  fi

  if [[ -n "${base_ref}" ]]; then
    if git -C "${repo_root}" diff --quiet "${base_ref}" -- "rfd/${entry_name}"; then
      return 1
    fi
    return 0
  fi

  return 1
}

valid_state_transition() {
  local previous="$1"
  local current="$2"

  [[ "${previous}" == "${current}" ]] && return 0

  case "${previous}:${current}" in
  prediscussion:ideation | prediscussion:discussion | prediscussion:published | prediscussion:committed | prediscussion:abandoned | \
    ideation:prediscussion | ideation:discussion | ideation:published | ideation:committed | ideation:abandoned | \
    discussion:published | discussion:committed | discussion:abandoned | \
    published:committed | published:abandoned)
    return 0
    ;;
  *) return 1 ;;
  esac
}

read_checklist_counts() {
  awk '
    BEGIN { complete = 0; total = 0; malformed = 0; org_block = 0; markdown_fence = 0 }
    tolower($0) ~ /^[[:space:]]*#\+begin_/ { org_block++; next }
    tolower($0) ~ /^[[:space:]]*#\+end_/ { if (org_block > 0) org_block--; next }
    !org_block && $0 ~ /^[[:space:]]*(```|~~~)/ { markdown_fence = !markdown_fence; next }
    org_block || markdown_fence { next }
    /^([[:space:]]*[-+*]|[[:space:]]*[0-9]+\.)[[:space:]]+\[[Xx ]\][[:space:]]+[^[:space:]]/ {
      total++
      if ($0 ~ /\[[Xx]\]/) complete++
      next
    }
    /^([[:space:]]*[-+*]|[[:space:]]*[0-9]+\.)[[:space:]]+\[[^]]*\]([[:space:]]|$)/ {
      malformed++
    }
    END { printf "%d %d %d\n", complete, total, malformed }
  ' "$1"
}

read_design_checkbox_count() {
  awk '
    BEGIN { count = 0; org_block = 0; markdown_fence = 0; asciidoc_block = 0 }
    tolower($0) ~ /^[[:space:]]*#\+begin_/ { org_block++; next }
    tolower($0) ~ /^[[:space:]]*#\+end_/ { if (org_block > 0) org_block--; next }
    !org_block && $0 ~ /^[[:space:]]*(```|~~~)/ { markdown_fence = !markdown_fence; next }
    !org_block && !markdown_fence && $0 ~ /^[[:space:]]*(----|\.\.\.\.|====|____|\*\*\*\*)[[:space:]]*$/ {
      asciidoc_block = !asciidoc_block
      next
    }
    org_block || markdown_fence || asciidoc_block { next }
    /^([[:space:]]*[-+*]|[[:space:]]*[0-9]+\.)[[:space:]]+\[[Xx ]\][[:space:]]+[^[:space:]]/ { count++ }
    END { print count }
  ' "$1"
}

printf "%s%-4s  %-13s  %-9s  %-40s  %s%s\n" "${color_bold}" "RFD" "State" "Progress" "Labels" "Title" "${color_reset}"
printf "%s%-4s  %-13s  %-9s  %-40s  %s%s\n" "${color_dim}" "----" "-------------" "---------" "----------------------------------------" "------------------------------" "${color_reset}"

failures=0
found=0

shopt -s nullglob dotglob
current_entries=("${rfd_root}"/*)
shopt -u nullglob dotglob

entry_names=()

for entry in "${current_entries[@]}"; do
  entry_names+=("$(basename "${entry}")")
done

while IFS= read -r base_entry_name; do
  [[ -n "${base_entry_name}" ]] && entry_names+=("${base_entry_name}")
done < <(list_base_entry_names)

mapfile -t entry_names < <(printf '%s\n' "${entry_names[@]}" | sort -u)

for entry_name in "${entry_names[@]}"; do
  entry="${rfd_root}/${entry_name}"

  if [[ "${entry_name}" == "README.md" ]]; then
    continue
  fi

  previous_state="$(read_base_state "${entry_name}")"

  if [[ ! -e "${entry}" && -n "${previous_state}" ]]; then
    printf "%shistorical RFD must not be deleted%s: %s\n" "${color_red}" "${color_reset}" "${entry_name}" >&2
    failures=$((failures + 1))
    found=1
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
  complete_count=0
  total_count=0

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
      ;;
    IMPLEMENTATION.md)
      expected_heading="# RFD ${entry_name} implementation checklist"
      ;;
    esac

    if [[ "$(head -n 1 "${implementation}")" != "${expected_heading}" ]]; then
      printf "%sinvalid implementation checklist heading%s: %s/%s\n" "${color_red}" "${color_reset}" "${entry_name}" "${implementation_name}" >&2
      failures=$((failures + 1))
    fi

    case "${implementation_name}" in
    IMPLEMENTATION.org)
      backlink_pattern='\[\[file:README\.adoc\]\[[^]]+\]\]'
      ;;
    IMPLEMENTATION.md)
      backlink_pattern='\[[^]]+\]\(README\.adoc\)'
      ;;
    esac

    if ! grep -Eq "${backlink_pattern}" "${implementation}"; then
      printf "%simplementation checklist must link to its RFD%s: %s/%s\n" "${color_red}" "${color_reset}" "${entry_name}" "${implementation_name}" >&2
      failures=$((failures + 1))
    fi

    if ! grep -Eq "link:${implementation_name}\\[[^]]+\\]" "${source}"; then
      printf "%sRFD must link to its implementation checklist%s: %s/README.adoc\n" "${color_red}" "${color_reset}" "${entry_name}" >&2
      failures=$((failures + 1))
    fi

    counts="$(read_checklist_counts "${implementation}")"
    complete_count="${counts%% *}"
    remainder_counts="${counts#* }"
    total_count="${remainder_counts%% *}"
    malformed_count="${counts##* }"

    if [[ "${malformed_count}" -gt 0 ]]; then
      printf "%smalformed implementation task%s: %s/%s\n" "${color_red}" "${color_reset}" "${entry_name}" "${implementation_name}" >&2
      failures=$((failures + 1))
    fi
  fi

  if [[ "$(read_design_checkbox_count "${source}")" -gt 0 ]]; then
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

  if [[ "${state}" == "committed" ]]; then
    if [[ "${total_count}" -eq 0 ]]; then
      printf "%scommitted RFD requires a non-empty implementation checklist%s: %s\n" "${color_red}" "${color_reset}" "${entry_name}" >&2
      failures=$((failures + 1))
    elif [[ "${complete_count}" -ne "${total_count}" ]]; then
      printf "%scommitted RFD has incomplete implementation tasks%s: %s (%s/%s complete)\n" "${color_red}" "${color_reset}" "${entry_name}" "${complete_count}" "${total_count}" >&2
      failures=$((failures + 1))
    fi
  fi

  if [[ -n "${previous_state}" ]] && ! valid_state_transition "${previous_state}" "${state}"; then
    printf "%sinvalid RFD state transition%s: %s changed from %s to %s\n" "${color_red}" "${color_reset}" "${entry_name}" "${previous_state}" "${state}" >&2
    failures=$((failures + 1))
  fi

  if [[ "${previous_state}" =~ ^(committed|abandoned)$ ]] && rfd_changed_from_base "${entry_name}"; then
    printf "%sfinal RFD content is immutable%s: %s (%s)\n" "${color_red}" "${color_reset}" "${entry_name}" "${previous_state}" >&2
    failures=$((failures + 1))
  fi

  state_field="$(printf '%-13s' "${state:-\(missing\)}")"
  progress_field="$(printf '%-9s' "${complete_count}/${total_count}")"
  state_text="$(colorize_state "${state}" "${state_field}")"
  progress_text="$(colorize_progress "${complete_count}" "${total_count}" "${progress_field}")"
  printf "%-4s  %s  %s  %-40s  %s\n" "${entry_name}" "${state_text}" "${progress_text}" "${labels:-\(missing labels\)}" "${title:-\(missing title\)}"
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
