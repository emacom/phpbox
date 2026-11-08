# shellcheck shell=bash

UPDATE_REPO="emacom/phpbox"
UPDATE_BRANCH="main"
UPDATE_INTERVAL=86400
UPDATE_FILE="$CACHE_DIR/update-check"

# Fetch the latest upstream commit SHA into UPDATE_FILE in the background, at most once per UPDATE_INTERVAL seconds.
update_refresh() {
  local -a auth=()
  [[ -f "$UPDATE_FILE" ]] && (( $(date +%s) - $(stat -c %Y "$UPDATE_FILE") < UPDATE_INTERVAL )) && return 0
  mkdir -p "$CACHE_DIR" && touch "$UPDATE_FILE" || return 0
  [[ -n "$GITHUB_TOKEN" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  (
    trap '' HUP
    curl -fsS --max-time 5 -H 'Accept: application/vnd.github.sha' "${auth[@]}" \
      "https://api.github.com/repos/$UPDATE_REPO/commits/$UPDATE_BRANCH" > "$UPDATE_FILE.tmp" \
      && mv "$UPDATE_FILE.tmp" "$UPDATE_FILE"
    rm -f "$UPDATE_FILE.tmp"
  ) </dev/null >/dev/null 2>&1 &
}

# Return 0 when the cached upstream SHA is not contained in the local HEAD.
update_available() {
  local sha
  [[ -s "$UPDATE_FILE" ]] || return 1
  sha=$(<"$UPDATE_FILE")
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  ! git -C "$ROOT" merge-base --is-ancestor "$sha" HEAD 2>/dev/null
}

# Print a notice about a newer phpbox on GitHub to an interactive stderr; UPDATE_CHECK=0 disables it.
update_notice() {
  [[ "$UPDATE_CHECK" == 1 && -t 2 && -e "$ROOT/.git" ]] || return 0
  update_refresh
  update_available || return 0
  printf '%s↑%s New phpbox version on GitHub. Update: git -C %s pull\n' $'\e[33m' "$c_off" "$ROOT" >&2
}
