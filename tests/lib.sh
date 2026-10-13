# shellcheck shell=bash

PASSED=0 FAILED=0 SKIPPED=0 FAILURES=()
t_green=$'\e[32m' t_red=$'\e[31m' t_yellow=$'\e[33m' t_bold=$'\e[1m' t_dim=$'\e[2m' t_off=$'\e[0m'
if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then t_green="" t_red="" t_yellow="" t_bold="" t_dim="" t_off=""; fi

# Print a group header: section <title>
section() { printf '\n%s%s%s\n' "$t_bold" "$1" "$t_off"; }

# Record a passed check: pass <description>
pass() { PASSED=$((PASSED + 1)); printf '  %s✔%s %s\n' "$t_green" "$t_off" "$1"; }

# Record a failed check with details: fail <description> <details>
fail() {
  FAILED=$((FAILED + 1)); FAILURES+=("$1")
  printf '  %s✖ %s%s\n' "$t_red" "$1" "$t_off"
  [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed "s/^/      $t_dim/; s/\$/$t_off/"
}

# Record a skipped check: skip <description> <reason>
skip() { SKIPPED=$((SKIPPED + 1)); printf '  %s○ %s (%s)%s\n' "$t_yellow" "$1" "$2" "$t_off"; }

# Pass when the command succeeds: check <description> <command...>
check() {
  local name="$1" out; shift
  if out=$("$@" 2>&1); then pass "$name"; else fail "$name" "$out"; fi
}

# Pass when the command fails: check_fails <description> <command...>
check_fails() {
  local name="$1" out; shift
  if out=$("$@" 2>&1); then fail "$name" "command succeeded: $out"; else pass "$name"; fi
}

# Pass when both strings are equal: eq <description> <actual> <expected>
eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected: $3"$'\n'"actual:   $2"; fi
}

# Pass when the text contains the fragment: contains <description> <text> <fragment>
contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "missing: $3"$'\n'"in:      ${2:0:300}"; fi
}

# Print the totals and exit 1 when a check failed.
summary() {
  printf '\n%s%d passed%s, %s%d failed%s, %d skipped\n' "$t_green" "$PASSED" "$t_off" "$t_red" "$FAILED" "$t_off" "$SKIPPED"
  if [[ $FAILED -gt 0 ]]; then
    printf '%sFailed:%s\n' "$t_red" "$t_off"
    printf '  - %s\n' "${FAILURES[@]}"
    exit 1
  fi
}
