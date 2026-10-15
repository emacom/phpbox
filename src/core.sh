# shellcheck shell=bash disable=SC2034

c_blue=$'\e[34m' c_green=$'\e[32m' c_red=$'\e[31m' c_off=$'\e[0m'
log() { printf '%s→%s %s\n' "$c_blue" "$c_off" "$*"; }
ok()  { printf '%s✔%s %s\n' "$c_green" "$c_off" "$*"; }
die() { printf '%s✖%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

# Print the names of available platforms.
platforms() { for f in "$ROOT"/platforms/*/platform.sh; do basename "$(dirname "$f")"; done | paste -sd' '; }

# Print the names of available services from docker/services.
services() { for f in "$ROOT"/docker/services/*.yml; do basename "$f" .yml; done | paste -sd' '; }

# Print the names of SERVICES without image tags.
service_names() { local s; for s in $SERVICES; do echo "${s%%:*}"; done | paste -sd' '; }

# Return 0 when SERVICES contains the service with or without a tag: has_service <name>
has_service() { [[ " $(service_names) " == *" $1 "* ]]; }

# Add a service to SERVICES once; a given tag replaces the tag of an added service: add_service <name[:tag]>
add_service() {
  local name="${1%%:*}" s out=""
  [[ -f "$ROOT/docker/services/$name.yml" ]] || die "Unknown service '$name'. Available: $(services)"
  [[ "$1" != *:* || "${1#*:}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "Invalid image tag in '$1'"
  if ! has_service "$name"; then
    SERVICES="${SERVICES:+$SERVICES }$1"
    return 0
  fi
  [[ "$1" == *:* ]] || return 0
  for s in $SERVICES; do
    [[ "${s%%:*}" == "$name" ]] && s="$1"
    out="${out:+$out }$s"
  done
  SERVICES="$out"
}

# Set the image tag of a service listed in SERVICES without one: service_default <name> <tag>
service_default() {
  [[ " $SERVICES " == *" $1 "* ]] && add_service "$1:$2"
  return 0
}

# Print compose variables with the image tags from SERVICES, e.g. REDIS_TAG=7.2-alpine.
service_tags() {
  local s n
  for s in $SERVICES; do
    [[ "$s" == *:* ]] || continue
    n="${s%%:*}"; n="${n^^}"
    echo "${n//-/_}_TAG=${s#*:}"
  done
}

# Parse options shared by create and clone into OPT_NAME, OPT_PHP, OPT_BRANCH, SHOP_LANG and SERVICES: parse_options <args...>
parse_options() {
  local svc
  OPT_NAME="" OPT_PHP="" OPT_BRANCH="" SERVICES=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)   OPT_NAME="$2"; shift 2 ;;
      --php)    OPT_PHP="$2"; shift 2 ;;
      --lang)   SHOP_LANG="$2"; shift 2 ;;
      --branch) OPT_BRANCH="$2"; shift 2 ;;
      *) svc="${1#--}"
         if [[ "$1" == --* && -f "$ROOT/docker/services/${svc%%:*}.yml" ]]; then add_service "$svc"; shift
         elif declare -F p_option >/dev/null && p_option "$1" "${2:-}"; then shift 2
         else die "Unknown option: $1"; fi ;;
    esac
  done
}

# Load platforms/<name>/platform.sh over the default hooks: load_platform <name>
load_platform() {
  local f="$ROOT/platforms/$1/platform.sh"
  [[ -f "$f" ]] || die "Unknown platform '$1'. Available: $(platforms)"
  PLATFORM="$1"
  PLATFORM_DIR="$ROOT/platforms/$1"
  P_COMPOSE=()
  P_NGINX_CONF="$PLATFORM_DIR/nginx.conf"
  P_ENV_KEYS=""
  P_CRON=""
  # shellcheck source=/dev/null
  source "$f"
}

# Set WWW_DIR to boxes/<name>/<name>, or to boxes/<name>/www for boxes created before the rename.
set_www_dir() {
  WWW_DIR="$BOXES_DIR/$NAME/$NAME"
  [[ -d "$BOXES_DIR/$NAME/www" ]] && WWW_DIR="$BOXES_DIR/$NAME/www"
  return 0
}

# Load an existing box from boxes/<name>/.env together with its platform: load_env <name>
load_env() {
  NAME="${1:-}"; [[ -n "$NAME" ]] || die "Environment name required (phpbox list)"
  ENV_FILE="$BOXES_DIR/$NAME/.env"
  [[ -f "$ENV_FILE" ]] || die "Environment '$NAME' does not exist"
  set_www_dir
  SHOP_HOST=localhost KIND=fresh SERVICES="" DB_NAME=shop SEARCH=""
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  [[ -n "$SEARCH" ]] && add_service "$SEARCH"
  load_platform "$PLATFORM"
}

# Validate a new box name and set NAME, ports, host and paths: init_env <name>
init_env() {
  NAME="$1"
  [[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Name: lowercase letters, digits and '-' only"
  [[ " $SHARED_HOSTS " == *" $NAME "* ]] && die "Name '$NAME' is reserved for $NAME.localhost"
  [[ " snapshot nginx " == *" $NAME "* ]] && die "Name '$NAME' is reserved for boxes/<name>/$NAME"
  [[ -e "$BOXES_DIR/$NAME" ]] && die "Environment '$NAME' already exists (phpbox remove $NAME or --name)"
  PORT=$(next_port)
  DB_PORT=$((PORT + DB_PORT_OFFSET))
  SHOP_HOST="$NAME.localhost"
  DB_NAME="${NAME//-/_}"
  HOST_UID=$(id -u) HOST_GID=$(id -g)
  set_www_dir
  ENV_FILE="$BOXES_DIR/$NAME/.env"
}

# Apply --php, check the PHP image and write boxes/<name>/.env.
save_env() {
  local k
  [[ -n "$OPT_PHP" ]] && PHP_VERSION="$OPT_PHP"
  [[ " $PHP_VERSIONS " == *" $PHP_VERSION "* ]] || die "No image $PHP_IMAGE:$PHP_VERSION (available: $PHP_VERSIONS)"
  ok "$P_TITLE $VERSION (PHP $PHP_VERSION, $DB_IMAGE${SERVICES:+, $SERVICES})"
  mkdir -p "$BOXES_DIR/$NAME"
  for k in $ENV_KEYS $P_ENV_KEYS; do printf '%s=%q\n' "$k" "${!k:-}"; done > "$ENV_FILE"
}

# Return 0 when a port is used by a box, a shared service or another program: port_taken <port>
port_taken() {
  grep -qsE "^(PORT|DB_PORT)=$1$" "$BOXES_DIR"/*/.env && return 0
  [[ " $HTTP_PORT $HTTPS_PORT $MAILPIT_PORT $PHPMYADMIN_PORT " == *" $1 "* ]] && return 0
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# Print the first free port slot from BASE_PORT whose database port is free too.
next_port() {
  local p="$BASE_PORT"
  while port_taken "$p" || port_taken "$((p + DB_PORT_OFFSET))"; do p=$((p + 1)); done
  echo "$p"
}

# Print the shop host with HTTPS_PORT when it is not 443.
shop_hostport() { if [[ "$HTTPS_PORT" == 443 ]]; then echo "$SHOP_HOST"; else echo "$SHOP_HOST:$HTTPS_PORT"; fi; }

# Print the shop URL.
shop_url() { echo "https://$(shop_hostport)"; }

# Map SHOP_LANG to a full locale, e.g. pl to pl_PL.
shop_locale() {
  case "$SHOP_LANG" in
    en) echo en_US ;; cs) echo cs_CZ ;; uk) echo uk_UA ;; da) echo da_DK ;; sv) echo sv_SE ;;
    *)  echo "${SHOP_LANG}_${SHOP_LANG^^}" ;;
  esac
}

# Resolve versions with src/versions.py: versions_query <source> <list|resolve> [args...] < json
versions_query() {
  command -v python3 >/dev/null || die "python3 is required"
  PHPBOX_PHP="$PHP_VERSIONS" python3 -I "$ROOT/src/versions.py" "$@"
}

# Print COMPOSER_AUTH json from the host auth.json and the keys in phpbox.conf.
composer_auth() {
  MAGENTO_PUBLIC_KEY="$MAGENTO_PUBLIC_KEY" MAGENTO_PRIVATE_KEY="$MAGENTO_PRIVATE_KEY" GITHUB_TOKEN="$GITHUB_TOKEN" \
    python3 -I "$ROOT/src/composer_auth.py" "$HOME/.composer/auth.json" "$HOME/.config/composer/auth.json"
}

# Set VERSION from git, PHP_VERSION from composer.json and DB_IMAGE; default clone hook.
p_clone_detect() {
  local rc=0
  VERSION=$(git -C "$WWW_DIR" describe --tags --always 2>/dev/null || echo "-")
  PHP_VERSION="${PHP_VERSIONS##* }"
  if [[ -f "$WWW_DIR/composer.json" ]]; then
    PHP_VERSION=$(versions_query project resolve < "$WWW_DIR/composer.json") || rc=$?
    if (( rc == 2 )) && [[ -z "$OPT_PHP" ]]; then
      die "composer.json requires PHP outside $PHP_IMAGE images ($PHP_VERSIONS); force --php"
    fi
  fi
  DB_IMAGE="mariadb:11.4"
}

# Run composer install when composer.json exists; default clone hook.
p_project_install() {
  [[ -f "$WWW_DIR/composer.json" ]] || return 0
  printf '%s\n' 'set -euo pipefail' 'echo "→ composer install…"' 'composer install --no-interaction --no-progress' \
    | COMPOSER_AUTH="$(composer_auth)" php_run -e COMPOSER_AUTH
}

# Print the database connection data; default db-import hook.
p_after_import() {
  log "$P_TITLE has no import step; configure the application: host db, database $DB_NAME, user $DB_USER / $DB_PASS"
}
