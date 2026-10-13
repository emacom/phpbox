# shellcheck shell=bash disable=SC2034
P_TITLE="Shopware"
P_SHORT="sw"
P_CRON="bin/console scheduled-task:run --no-wait && bin/console messenger:consume async --time-limit=50"
SW_REPO="https://repo.packagist.org"
SW_CORE="shopware/core"
SW_PROJECT="shopware/production"

_sw_meta() { curl -fsSL "$SW_REPO/p2/$SW_CORE.json"; }

# Print the .env.local lines connecting the shop to the box database, address, Mailpit and search service.
_sw_env_local() {
  local es=0
  { has_service opensearch || has_service elasticsearch; } && es=1
  cat <<ENV
APP_ENV=dev
APP_URL=$(shop_url)
DATABASE_URL=mysql://$DB_USER:$DB_PASS@db:3306/$DB_NAME
MAILER_DSN=smtp://phpbox-mailpit:1025
OPENSEARCH_URL=http://search:9200
SHOPWARE_ES_ENABLED=$es
SHOPWARE_ES_INDEXING_ENABLED=$es
ENV
}

# Set the box values in www/.env.local, keep its other lines and a copy as .env.local.<timestamp>.orig.
_sw_write_env() {
  local f="$WWW_DIR/.env.local" rest=""
  if [[ -s "$f" ]]; then
    cp "$f" "$f.$(date +%s).orig"
    rest=$(grep -vE '^(APP_ENV|APP_URL|DATABASE_URL|MAILER_DSN|OPENSEARCH_URL|SHOPWARE_ES_ENABLED|SHOPWARE_ES_INDEXING_ENABLED)=' "$f" || true)
  fi
  { [[ -z "$rest" ]] || printf '%s\n' "$rest"; _sw_env_local; } > "$f"
}

p_resolve() {
  local query="$1" out
  [[ "$query" == latest ]] || query="v${query#v}"
  out=$(_sw_meta | versions_query composer resolve "$SW_CORE" "$query") \
    || die "Version '$1' not found (phpbox versions shopware)"
  read -r VERSION PHP_VERSION _ _ <<<"$out"
  VERSION="${VERSION#v}"
  DOWNLOAD_URL="-"
  DB_IMAGE="mariadb:11.4"
}

p_versions() { _sw_meta | versions_query composer list "$SW_CORE" | sed -E 's/^v//' | head -40; }

p_install() {
  php_run -e SW_PROJECT="$SW_PROJECT" -e SW_VERSION="$VERSION" -e COMPOSER_AUTH="$(composer_auth)" <<'SH'
set -euo pipefail
echo "→ composer create-project $SW_PROJECT:$SW_VERSION (several minutes)…"
composer create-project --no-interaction --no-progress --no-install "$SW_PROJECT:$SW_VERSION" .
composer config --json extra.symfony.docker false
composer install --no-interaction --no-progress
SH
  _sw_write_env
  php_run -e SW_NAME="$P_TITLE $VERSION" -e SW_LOCALE="$(shop_locale | tr _ -)" -e SW_CURRENCY="$SHOP_CURRENCY" <<'SH'
set -euo pipefail
echo "→ system:install…"
bin/console system:install --basic-setup --force --no-interaction \
  --shop-name="$SW_NAME" --shop-email="$ADMIN_EMAIL" --shop-locale="$SW_LOCALE" --shop-currency="$SW_CURRENCY"
if [[ "$ADMIN_USER" == admin ]]; then
  bin/console user:change-password admin --password="$ADMIN_PASSWORD"
else
  bin/console user:create "$ADMIN_USER" --admin --email="$ADMIN_EMAIL" --password="$ADMIN_PASSWORD" --firstName=Admin --lastName=PhpBox
fi
echo "→ Installed"
SH
  db_exec "$DB_NAME" -e "UPDATE user SET email = '$ADMIN_EMAIL' WHERE username = 'admin' AND '$ADMIN_USER' = 'admin'"
}

# Set PHP_VERSION from shopware/core in composer.lock and config.platform.php in composer.json; VERSION from shopware/core.
p_clone_detect() {
  local out rc=0
  [[ -f "$WWW_DIR/composer.lock" ]] || die "No composer.lock in repository"
  out=$(python3 -I - "$WWW_DIR/composer.lock" "$WWW_DIR/composer.json" <<'PY'
import json, sys
core = next((p for p in json.load(open(sys.argv[1]))["packages"] if p["name"] == "shopware/core"), None)
if not core:
    sys.exit(1)
project = json.load(open(sys.argv[2]))
print(core["version"].lstrip("v"))
print(json.dumps({"require": {"php": core.get("require", {}).get("php", "")}, "config": project.get("config", {})}))
PY
  ) || die "shopware/core not found in composer.lock"
  VERSION=$(head -1 <<<"$out")
  PHP_VERSION=$(tail -1 <<<"$out" | versions_query project resolve) || rc=$?
  (( rc == 2 )) && [[ -z "$OPT_PHP" ]] && die "shopware/core requires PHP outside $PHP_IMAGE images ($PHP_VERSIONS); force --php"
  DB_IMAGE="mariadb:11.4"
}

p_project_install() {
  _sw_write_env
  php_run -e COMPOSER_AUTH="$(composer_auth)" <<'SH'
set -euo pipefail
echo "→ composer install --no-scripts (the database is empty until db-import)…"
composer install --no-interaction --no-progress --no-scripts
SH
}

# Point sales channel domains at the box address, send mail to Mailpit and set the admin password.
p_after_import() {
  local url
  url=$(shop_url)
  _sw_write_env
  log "Configuring database for $url…"
  db_exec "$DB_NAME" <<SQL
UPDATE IGNORE sales_channel_domain
  SET url = CONCAT('$url', IF(LOCATE('/', url, 9) > 0, SUBSTRING(url, LOCATE('/', url, 9)), ''))
  WHERE url LIKE 'http%';
DELETE FROM system_config WHERE configuration_key LIKE 'core.mailerSettings.%';
SQL
  log "assets:install, theme:compile, admin account…"
  php_run <<'SH'
set -euo pipefail
touch install.lock
bin/console assets:install
bin/console theme:compile
bin/console user:change-password "$ADMIN_USER" --password="$ADMIN_PASSWORD" \
  || bin/console user:create "$ADMIN_USER" --admin --email="$ADMIN_EMAIL" --password="$ADMIN_PASSWORD" \
  --firstName=Admin --lastName=PhpBox
bin/console cache:clear
SH
}

# Point a copied database and .env.local at this environment's host: p_rehost <old-url>
p_rehost() {
  _sw_write_env
  db_exec "$DB_NAME" -e "UPDATE sales_channel_domain SET url = REPLACE(url, '$1', '$(shop_url)')"
  p_clear_cache
}

p_snapshot_excludes() { echo "var/cache var/log"; }

p_clear_cache() { rm -rf "$WWW_DIR"/var/cache/*; }

p_info() {
  cat <<INFO
  Shop:    $(shop_url)
  Admin:   $(shop_url)/admin   ($ADMIN_USER / $ADMIN_PASSWORD)
INFO
}
