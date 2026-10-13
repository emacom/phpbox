# shellcheck shell=bash disable=SC2034
P_TITLE="Symfony"
P_SHORT="sf"
SF_REPO="https://repo.packagist.org"
SF_PACKAGE="symfony/skeleton"

_sf_meta() { curl -fsSL "$SF_REPO/p2/$SF_PACKAGE.json"; }

# Print the .env.local lines connecting the app to the box database and Mailpit.
_sf_env_local() {
  cat <<ENV
APP_ENV=dev
DATABASE_URL="mysql://$DB_USER:$DB_PASS@db:3306/$DB_NAME?serverVersion=${DB_IMAGE#mariadb:}.0-MariaDB&charset=utf8mb4"
MAILER_DSN=smtp://phpbox-mailpit:1025
ENV
}

# Set the box values in www/.env.local, keep its other lines and a copy as .env.local.<timestamp>.orig.
_sf_write_env() {
  local f="$WWW_DIR/.env.local" rest=""
  if [[ -f "$f" ]]; then
    cp "$f" "$f.$(date +%s).orig"
    rest=$(grep -vE '^(APP_ENV|DATABASE_URL|MAILER_DSN)=' "$f" || true)
  fi
  { [[ -z "$rest" ]] || printf '%s\n' "$rest"; _sf_env_local; } > "$f"
}

p_resolve() {
  local query="$1" out
  [[ "$query" == latest ]] || query="v${query#v}"
  out=$(_sf_meta | versions_query composer resolve "$SF_PACKAGE" "$query") \
    || die "Version '$1' not found (phpbox versions symfony)"
  read -r VERSION PHP_VERSION _ _ <<<"$out"
  VERSION="${VERSION#v}"; VERSION="${VERSION%.99}"
  DOWNLOAD_URL="-"
  DB_IMAGE="mariadb:11.4"
}

p_versions() { _sf_meta | versions_query composer list "$SF_PACKAGE" | sed -E 's/^v([0-9]+\.[0-9]+)\.99 /\1    /'; }

p_install() {
  php_run -e SF_PACKAGE="$SF_PACKAGE" -e SF_VERSION="$VERSION" -e COMPOSER_AUTH="$(composer_auth)" <<'SH'
set -euo pipefail
echo "→ composer create-project $SF_PACKAGE:$SF_VERSION.*…"
composer create-project --no-interaction --no-progress "$SF_PACKAGE:$SF_VERSION.*" .
composer config --json extra.symfony.docker false
echo "→ composer require webapp…"
composer require --no-interaction --no-progress webapp
SH
  _sf_write_env
  php_run <<'SH'
set -euo pipefail
php bin/console dbal:run-sql 'SELECT 1' >/dev/null
php bin/console cache:clear
echo "→ Installed"
SH
}

p_project_install() {
  php_run -e COMPOSER_AUTH="$(composer_auth)" <<'SH'
set -euo pipefail
echo "→ composer install…"
composer install --no-interaction --no-progress
SH
  _sf_write_env
}

p_after_import() {
  _sf_write_env
  log ".env.local points at database $DB_NAME"
  p_clear_cache
}

p_snapshot_excludes() { echo "var/cache var/log"; }

p_clear_cache() { rm -rf "$WWW_DIR"/var/cache/*; }

p_info() {
  cat <<INFO
  App:     $(shop_url)
  Debug:   $(shop_url)/_profiler
INFO
}
