#!/usr/bin/env bash
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$TESTS_DIR")"
source "$TESTS_DIR/lib.sh"

PLATFORM="${1:-woocommerce}"
VERSION="${2:-latest}"
BOX="t-${PLATFORM:0:2}"
HTTP=18080 HTTPS=18443

if docker ps --format '{{.Names}}' | grep -qx phpbox-proxy; then
  echo "phpbox is running. Stop it first: phpbox down (phpbox up restores your boxes)"
  exit 1
fi

TMP=$(mktemp -d)
LOG="$TMP/phpbox.log"
export PHPBOX_BOXES_DIR="$TMP/boxes" PHPBOX_CONF="$TMP/phpbox.conf" NO_COLOR=1
mkdir -p "$PHPBOX_BOXES_DIR"
{
  [[ -f "$ROOT_DIR/phpbox.conf" ]] && grep -E '^(MAGENTO_|GITHUB_TOKEN)' "$ROOT_DIR/phpbox.conf"
  printf 'HTTP_PORT=%s\nHTTPS_PORT=%s\nBASE_PORT=28080\n' "$HTTP" "$HTTPS"
} > "$PHPBOX_CONF"

# Remove every test box, the shared containers and the temporary directory.
cleanup() {
  local env
  for env in "$PHPBOX_BOXES_DIR"/*/.env; do
    [[ -f "$env" ]] && "$ROOT_DIR/phpbox" remove "$(basename "$(dirname "$env")")" -y >>"$LOG" 2>&1
  done
  "$ROOT_DIR/phpbox" down >>"$LOG" 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

# Run phpbox with output in the log; on failure print the end of the log: step <description> <phpbox args...>
step() {
  local name="$1"; shift
  printf '\n$ phpbox %s\n' "$*" >>"$LOG"
  if "$ROOT_DIR/phpbox" "$@" >>"$LOG" 2>&1; then pass "$name"; else fail "$name" "$(tail -15 "$LOG")"; fi
}

# Print the HTTP status of a URL, retrying while the box warms up: status <url> [container]
status() {
  local code i
  for i in 1 2 3 4 5; do
    if [[ -n "${2:-}" ]]; then
      code=$(docker exec "$2" curl -s -o /dev/null -w '%{http_code}' "$1")
    else
      code=$(curl -s -o /dev/null -w '%{http_code}' "$1")
    fi
    [[ "$code" == 200 ]] && break
    sleep 2
  done
  echo "$code"
}

# Run SQL in the box database as root: sql <box> <query>
sql() { docker exec "phpbox-$1-db-1" mariadb -uroot -proot -N "${1//-/_}" -e "$2"; }

url="https://$BOX.localhost:$HTTPS"
printf '%sSmoke test: %s %s (log: %s)%s\n' "$t_bold" "$PLATFORM" "$VERSION" "$LOG" "$t_off"

section "Install"
step "create $PLATFORM $VERSION" create "$PLATFORM" "$VERSION" --name "$BOX"
eq "shop answers over HTTPS" "$(status "$url/")" 200
eq "php container reaches the shop (loopback)" "$(status "$url/" "phpbox-$BOX-php-1")" 200
contains "info shows the HTTPS address" "$("$ROOT_DIR/phpbox" info "$BOX")" "$url"
contains "list shows the box as running" "$("$ROOT_DIR/phpbox" list)" "running"

section "Mail"
docker exec "phpbox-$BOX-php-1" php -r 'mail("test@example.com", "phpbox smoke", "body");' >>"$LOG" 2>&1
sleep 1
contains "mail() lands in Mailpit" "$(curl -s "http://localhost:18025/api/v1/messages")" '"Subject":"phpbox smoke"'

section "Snapshot and reset"
sql "$BOX" "CREATE TABLE phpbox_smoke (id INT)" >>"$LOG" 2>&1
step "reset" reset "$BOX"
eq "reset removes a table created after the snapshot" "$(sql "$BOX" "SHOW TABLES LIKE 'phpbox_smoke'")" ""
eq "shop answers after reset" "$(status "$url/")" 200

section "Copy"
step "copy $BOX → $BOX-c" copy "$BOX" "$BOX-c"
eq "copy answers on its own address" "$(status "https://$BOX-c.localhost:$HTTPS/")" 200
step "remove the copy" remove "$BOX-c" -y

section "Stop and start"
step "stop" stop "$BOX"
eq "stopped box answers 502" "$(curl -s -o /dev/null -w '%{http_code}' "$url/")" 502
step "start" start "$BOX"
eq "started box answers 200" "$(status "$url/")" 200

section "phpbox down / up"
step "down" down
eq "no phpbox containers after down" "$(docker ps -a --format '{{.Names}}' | grep -c '^phpbox-')" 0
eq "down remembers the running box" "$(cat "$PHPBOX_BOXES_DIR/.up")" "$BOX"
step "up" up
eq "box answers after up" "$(status "$url/")" 200

if [[ "$PLATFORM" == woocommerce ]]; then
  section "Clone and db-import"
  repo="$TMP/repo"
  mkdir -p "$repo" && cp -r "$PHPBOX_BOXES_DIR/$BOX/www/wp-content" "$repo/"
  printf '/*\n!/wp-content/\n!/.gitignore\n' > "$repo/.gitignore"
  git -C "$repo" init -q && git -C "$repo" add -A && git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init
  docker exec -u "$(id -u)" "phpbox-$BOX-php-1" wp search-replace "$url" https://shop.example.com --all-tables --export=/cache/smoke-prod.sql --quiet
  mv "$ROOT_DIR/cache/smoke-prod.sql" "$TMP/prod.sql"
  step "clone woocommerce <repo with wp-content only>" clone woocommerce "$repo" --name "$BOX-p"
  step "db-import a dump with https://shop.example.com" db-import "$BOX-p" "$TMP/prod.sql"
  eq "imported shop answers on the box address" "$(status "https://$BOX-p.localhost:$HTTPS/")" 200
  contains "home option points to the box" "$(docker exec -u "$(id -u)" "phpbox-$BOX-p-php-1" wp option get home)" "https://$BOX-p.localhost:$HTTPS"
  check "admin password works after import" docker exec -u "$(id -u)" "phpbox-$BOX-p-php-1" wp user check-password admin admin123
  step "remove the cloned box" remove "$BOX-p" -y
fi

section "Remove"
step "remove" remove "$BOX" -y
check_fails "box directory is gone" test -e "$PHPBOX_BOXES_DIR/$BOX"
check_fails "box certificate is gone" test -e "$ROOT_DIR/cache/certs/$BOX.pem"

summary
