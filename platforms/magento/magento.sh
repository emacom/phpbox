# shellcheck shell=bash disable=SC2034
P_NGINX_CONF="$ROOT/platforms/magento/nginx.conf"
P_ENV_KEYS="MAGE_BASE SEARCH"
P_ADMIN_PATH="admin"
P_CRON="bin/magento cron:run"
M_DIR="$ROOT/platforms/magento"

P_COMPOSE=("$M_DIR/magento.yml")

# Fetch a path of the composer repository to stdout: _mage_curl <path>
_mage_curl() {
  if [[ -n "${M_AUTH:-}" ]]; then
    curl -fsSL --compressed -K <(printf 'user = "%s"\n' "$M_AUTH") "$M_REPO/$1"
  else
    curl -fsSL --compressed "$M_REPO/$1"
  fi
}

# Print the value of a python expression over JSON from stdin: _mage_json <expr> [args...]
_mage_json() {
  local expr="$1"; shift
  python3 -I -c "import json, sys; d = json.load(sys.stdin); a = sys.argv[1:]; print($expr)" "$@"
}

# Fetch composer metadata of the product package to stdout in p2 format.
_mage_meta() {
  local root inc url
  root=$(_mage_curl packages.json) || return 1
  if grep -q '"metadata-url"' <<<"$root"; then
    _mage_curl "p2/$M_PRODUCT.json"
    return
  fi
  for inc in $(_mage_json '"\n".join(p.replace("%hash%", v["sha256"]) for p, v in d["provider-includes"].items())' <<<"$root"); do
    url=$(_mage_curl "$inc" | _mage_json '"" if a[0] not in d["providers"] else a[1].replace("%package%", a[0]).replace("%hash%", d["providers"][a[0]]["sha256"])' \
      "$M_PRODUCT" "$(_mage_json 'd["providers-url"]' <<<"$root")")
    [[ -n "$url" ]] || continue
    _mage_curl "${url#/}" | _mage_json 'json.dumps({"packages": {a[0]: list(d["packages"][a[0]].values())}})' "$M_PRODUCT"
    return
  done
  return 1
}

_mage_check_auth() {
  [[ "$M_NEEDS_AUTH" == 1 ]] || return 0
  [[ -n "$MAGENTO_PUBLIC_KEY" && -n "$MAGENTO_PRIVATE_KEY" ]] \
    || die "Set MAGENTO_PUBLIC_KEY and MAGENTO_PRIVATE_KEY in phpbox.conf (marketplace.magento.com → Access Keys)"
  M_AUTH="$MAGENTO_PUBLIC_KEY:$MAGENTO_PRIVATE_KEY"
}

# Set DB_IMAGE, the search service and default service tags for a Magento base version: _mage_services <base> <min-minor>
_mage_services() {
  local base="$1" min="$2"
  local patch="${base#2.4.}"; patch="${patch%%-*}"
  local es="" os="" redis="" valkey="" rabbitmq=""
  [[ "$base" == 2.4.* && "$patch" =~ ^[0-9]+$ ]] || die "Unsupported Magento version: $base"
  (( patch >= min )) || die "Magento $base is not supported (minimum 2.4.$min)"
  case "$patch" in
    4|5) DB_IMAGE="mariadb:10.4"; SEARCH=elasticsearch; es=7.17.25; os=1.2.4; redis=6.2; rabbitmq=3.9 ;;
    6)   DB_IMAGE="mariadb:10.6"; SEARCH=opensearch; es=7.17.25; os=2.12.0; redis=7.0; rabbitmq=3.11 ;;
    7)   DB_IMAGE="mariadb:10.6"; SEARCH=opensearch; es=8.11.4; os=2.12.0; redis=7.2; rabbitmq=3.13 ;;
    8)   DB_IMAGE="mariadb:11.4"; SEARCH=opensearch; es=8.17.10; os=2.19.1; redis=7.2; valkey=8.1; rabbitmq=4.1 ;;
    *)   DB_IMAGE="mariadb:11.4"; SEARCH=opensearch; os=2.19.1; valkey=9.0; rabbitmq=4.3 ;;
  esac
  has_service opensearch && SEARCH=opensearch
  has_service elasticsearch && SEARCH=elasticsearch
  add_service "$SEARCH"
  [[ -n "$es" ]] && service_default elasticsearch "$es"
  service_default opensearch "$os"
  [[ -n "$redis" ]] && service_default redis "$redis-alpine"
  [[ -n "$valkey" ]] && service_default valkey "$valkey-alpine"
  service_default rabbitmq "$rabbitmq-management-alpine"
}

# Print the Magento search engine code for SEARCH and the elasticsearch tag.
_mage_engine() {
  [[ "$SEARCH" == opensearch ]] && { echo opensearch; return; }
  if [[ " $SERVICES " == *" elasticsearch:8"* ]]; then echo elasticsearch8; else echo elasticsearch7; fi
}

p_resolve() {
  _mage_check_auth
  local out
  out=$(_mage_meta | versions_query composer resolve "$M_PRODUCT" "$1") \
    || die "Version '$1' not found (phpbox versions $PLATFORM)"
  read -r VERSION PHP_VERSION MAGE_BASE DOWNLOAD_URL <<<"$out"
  _mage_services "$MAGE_BASE" 4
}

p_versions() { _mage_check_auth; _mage_meta | versions_query composer list "$M_PRODUCT"; }

p_install() {
  _mage_check_auth
  {
    cat <<'SH'
set -euo pipefail
echo "→ composer create-project $M_PROJECT=$M_VERSION (several minutes)…"
composer create-project --no-interaction --no-progress --repository-url="$M_REPO" "$M_PROJECT=$M_VERSION" .
SH
    cat "$M_DIR/icu-patch.sh"
    cat <<'SH'
echo "→ setup:install…"
if [[ "$M_SEARCH" == opensearch ]]; then
  search=(--search-engine=opensearch --opensearch-host=search --opensearch-port=9200)
else
  search=(--search-engine="$M_SEARCH" --elasticsearch-host=search --elasticsearch-port=9200)
fi
php -d memory_limit=-1 bin/magento setup:install \
  --base-url="$M_URL" --base-url-secure="$M_URL" --use-secure=1 --use-secure-admin=1 --backend-frontname="$M_ADMIN" --use-rewrites=1 \
  --db-host=db --db-name="$DB_NAME" --db-user="$DB_USER" --db-password="$DB_PASS" \
  --admin-firstname=Admin --admin-lastname=PhpBox --admin-email="$ADMIN_EMAIL" \
  --admin-user="$ADMIN_USER" --admin-password="$ADMIN_PASSWORD" \
  --language="$M_LOCALE" --currency="$M_CURRENCY" --timezone="$M_TZ" \
  "${search[@]}" --cleanup-database
mods=$(bin/magento module:status --enabled | grep -E '^Magento_(AdminAdobeImsTwoFactorAuth|TwoFactorAuth)$' || true)
[[ -z "$mods" ]] || bin/magento module:disable $mods
bin/magento deploy:mode:set developer
bin/magento config:set general/country/default "$M_COUNTRY"
bin/magento config:set admin/security/session_lifetime 86400
bin/magento indexer:reindex
bin/magento cache:flush
echo "→ Installed"
SH
  } | COMPOSER_AUTH="$(composer_auth)" php_run -e COMPOSER_AUTH \
    -e M_REPO="$M_REPO" -e M_PROJECT="$M_PROJECT" -e M_VERSION="$VERSION" -e M_URL="$(shop_url)/" \
    -e M_LOCALE="$(shop_locale)" -e M_CURRENCY="$SHOP_CURRENCY" -e M_TZ="$SHOP_TZ" -e M_COUNTRY="${SHOP_COUNTRY^^}" \
    -e M_ADMIN="$P_ADMIN_PATH" -e M_SEARCH="$(_mage_engine)"
  compose exec -T web nginx -s reload
}

p_clone_detect() {
  [[ -f "$WWW_DIR/composer.lock" ]] || die "No composer.lock in repository"
  local platform_php out rc=0
  platform_php=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("config", {}).get("platform", {}).get("php", ""))' "$WWW_DIR/composer.json")
  out=$(versions_query lock resolve "$platform_php" < "$WWW_DIR/composer.lock") || rc=$?
  (( rc == 2 )) && die "composer.lock requires PHP outside $PHP_IMAGE images ($PHP_VERSIONS); force --php"
  (( rc == 0 )) || die "Magento version not detected in composer.lock"
  read -r VERSION PHP_VERSION MAGE_BASE DOWNLOAD_URL <<<"$out"
  _mage_services "$MAGE_BASE" 4
}

p_project_install() {
  {
    echo 'set -euo pipefail'
    echo 'echo "→ composer install…"'
    echo 'composer install --no-interaction --no-progress'
    cat "$M_DIR/icu-patch.sh"
  } | COMPOSER_AUTH="$(composer_auth)" php_run -e COMPOSER_AUTH
}

# Rewrite URLs, search, mail and cache settings of an imported database for local use.
# Print the table prefix detected from the core_config_data table name.
_mage_prefix() {
  local table
  table=$(db_exec -N "$DB_NAME" -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME LIKE '%core_config_data' ORDER BY LENGTH(TABLE_NAME) LIMIT 1")
  [[ -n "$table" ]] || die "Database has no core_config_data table"
  echo "${table%core_config_data}"
}

p_after_import() {
  local table prefix url engine active
  prefix=$(_mage_prefix)
  table="${prefix}core_config_data"
  url="$(shop_url)/"
  engine=$(_mage_engine)
  active=$(db_exec -N "$DB_NAME" -e "SELECT value FROM \`$table\` WHERE path = 'catalog/search/engine' AND scope = 'default'" </dev/null)
  [[ "$active" == elasticsuite ]] || active="$engine"
  [[ -n "$prefix" ]] && log "Table prefix: $prefix"

  log "Configuring database for $url…"
  db_exec "$DB_NAME" <<SQL
DELETE FROM \`$table\` WHERE path IN (
  'web/unsecure/base_link_url','web/secure/base_link_url',
  'web/unsecure/base_static_url','web/secure/base_static_url',
  'web/unsecure/base_media_url','web/secure/base_media_url',
  'web/cookie/cookie_domain','web/cookie/cookie_path',
  'web/secure/use_in_frontend','web/secure/use_in_adminhtml',
  'web/secure/enable_hsts','web/secure/enable_upgrade_insecure',
  'admin/url/use_custom','admin/url/custom','admin/url/use_custom_path','admin/url/custom_path',
  'catalog/search/engine')
  OR (path LIKE 'catalog/search/%' AND (path LIKE '%server_hostname' OR path LIKE '%server_port'
      OR path LIKE '%index_prefix' OR path LIKE '%enable_auth' OR path LIKE '%username' OR path LIKE '%password'));
INSERT INTO \`$table\` (scope, scope_id, path, value) VALUES
  ('default', 0, 'web/unsecure/base_url', '$url'),
  ('default', 0, 'web/secure/base_url', '$url'),
  ('default', 0, 'web/secure/use_in_frontend', '1'),
  ('default', 0, 'web/secure/use_in_adminhtml', '1'),
  ('default', 0, 'catalog/search/engine', '$active'),
  ('default', 0, 'catalog/search/${engine}_server_hostname', 'search'),
  ('default', 0, 'catalog/search/${engine}_server_port', '9200'),
  ('default', 0, 'catalog/search/${engine}_index_prefix', 'magento2'),
  ('default', 0, 'catalog/search/${engine}_enable_auth', '0'),
  ('default', 0, 'system/smtp/transport', 'sendmail'),
  ('default', 0, 'system/full_page_cache/caching_application', '1'),
  ('default', 0, 'admin/security/session_lifetime', '86400')
  ON DUPLICATE KEY UPDATE value = VALUES(value);
UPDATE \`$table\` SET value = '0' WHERE path IN ('smtp/general/enabled', 'system/gmailsmtpapp/active');
UPDATE \`$table\` SET value = 'search:9200' WHERE path = 'smile_elasticsuite_core_base_settings/es_client/servers';
UPDATE \`$table\` SET value = '0' WHERE path IN ('smile_elasticsuite_core_base_settings/es_client/enable_https_mode',
  'smile_elasticsuite_core_base_settings/es_client/enable_http_auth');
SQL
  _mage_store_hosts "$prefix"

  log "app/etc/env.php, setup:upgrade, reindex…"
  {
    cat <<'SH'
set -euo pipefail
key=""
if [[ -f app/etc/env.php ]]; then
  key=$(php -r '$c = include "app/etc/env.php"; echo $c["crypt"]["key"] ?? "";')
  mv app/etc/env.php "app/etc/env.php.$(date +%s).orig"
fi
args=(--db-host=db --db-name="$DB_NAME" --db-user="$DB_USER" --db-password="$DB_PASS"
      --backend-frontname="$M_ADMIN")
[[ -n "$M_PREFIX" ]] && args+=(--db-prefix="$M_PREFIX")
[[ -n "$key" ]] && args+=(--key="$key")
kv=""
[[ " $SERVICES " == *" redis "* ]] && kv=redis
[[ " $SERVICES " == *" valkey "* ]] && kv=valkey
if [[ -z "$kv" ]]; then
  args+=(--session-save=files)
else
  args+=(--session-save=redis --session-save-redis-host="$kv" --session-save-redis-db=2
         --cache-backend=redis --cache-backend-redis-server="$kv" --cache-backend-redis-db=0
         --page-cache=redis --page-cache-redis-server="$kv" --page-cache-redis-db=1)
fi
if [[ " $SERVICES " == *" rabbitmq "* ]]; then
  args+=(--amqp-host=rabbitmq --amqp-port=5672 --amqp-user=guest --amqp-password=guest --amqp-virtualhost=/)
fi
if [[ "$(bin/magento setup:config:set --help)" == *--es-hosts* ]]; then
  args+=(--es-hosts=search:9200 --es-enable-ssl=0)
fi
bin/magento setup:config:set -n "${args[@]}"
php -r '$f = "app/etc/env.php"; $c = include $f; $c["install"]["date"] ??= date("D, d M Y H:i:s O"); $c["MAGE_MODE"] = "developer";
  file_put_contents($f, "<?php\nreturn " . var_export($c, true) . ";\n");'
SH
    cat "$M_DIR/icu-patch.sh"
    cat <<'SH'
bin/magento setup:upgrade
bin/magento admin:user:create --admin-user="$ADMIN_USER" --admin-password="$ADMIN_PASSWORD" \
  --admin-email="$ADMIN_EMAIL" --admin-firstname=Admin --admin-lastname=PhpBox \
  || echo "User $ADMIN_USER / $ADMIN_EMAIL already exists; log in with the imported account or run: bin/magento admin:user:unlock"
bin/magento indexer:reindex || echo "Reindex finished with errors; check: bin/magento indexer:status"
bin/magento cache:enable
bin/magento cache:flush
SH
  } | php_run -e M_PREFIX="$prefix" -e M_ADMIN="$P_ADMIN_PATH" -e SERVICES="$(service_names)" || return 1
  compose exec -T web nginx -s reload
}

# Give every website/store with its own base URL a host <code>.<name>.localhost and nginx run-code maps.
_mage_store_hosts() {
  local p="$1" dir="$BOXES_DIR/$NAME/nginx" scope id code host type
  : > "$dir/run_code.map"; : > "$dir/run_type.map"; : > "$dir/hosts"
  while IFS=$'\t' read -r scope id code; do
    [[ -n "$code" && "$code" != NULL ]] || continue
    host="$(tr '_A-Z' '-a-z' <<<"$code").$SHOP_HOST"
    if [[ "$scope" == websites ]]; then type=website; else type=store; fi
    db_exec "$DB_NAME" -e "UPDATE \`${p}core_config_data\` SET value = '$(SHOP_HOST=$host shop_url)/'
      WHERE scope = '$scope' AND scope_id = $id AND path IN ('web/unsecure/base_url', 'web/secure/base_url')"
    printf '%s %s;\n' "$host" "$code" >> "$dir/run_code.map"
    printf '%s %s;\n' "$host" "$type" >> "$dir/run_type.map"
    printf '%s %s %s\n' "$type" "$code" "$(SHOP_HOST=$host shop_url)" >> "$dir/hosts"
  done < <(db_exec -N "$DB_NAME" -e "
    SELECT DISTINCT c.scope, c.scope_id, COALESCE(w.code, s.code)
    FROM \`${p}core_config_data\` c
    LEFT JOIN \`${p}store_website\` w ON c.scope = 'websites' AND w.website_id = c.scope_id
    LEFT JOIN \`${p}store\` s ON c.scope = 'stores' AND s.store_id = c.scope_id
    WHERE c.path IN ('web/unsecure/base_url', 'web/secure/base_url') AND c.scope IN ('websites', 'stores')
    ORDER BY c.scope DESC, c.scope_id")
}

# Point a copied database at this environment's host: p_rehost <old-url>
p_rehost() {
  local prefix
  prefix=$(_mage_prefix)
  db_exec "$DB_NAME" -e "UPDATE \`${prefix}core_config_data\` SET value = '$(shop_url)/'
    WHERE scope = 'default' AND path IN ('web/unsecure/base_url', 'web/secure/base_url')"
  _mage_store_hosts "$prefix"
  compose exec -T web nginx -s reload
  p_clear_cache
}

p_snapshot_excludes() { echo "var/cache var/page_cache var/session var/log var/tmp var/view_preprocessed pub/static"; }

p_clear_cache() {
  php_run <<'SH'
set -euo pipefail
rm -rf var/cache/* var/page_cache/* var/view_preprocessed/* pub/static/frontend pub/static/adminhtml
bin/magento indexer:reindex >/dev/null
bin/magento cache:flush >/dev/null
SH
}

p_info() {
  cat <<INFO
  Shop:    $(shop_url)
  Admin:   $(shop_url)/$P_ADMIN_PATH   ($ADMIN_USER / $ADMIN_PASSWORD)
INFO
  local f="$BOXES_DIR/$NAME/nginx/hosts" type code url
  [[ -s "$f" ]] && while read -r type code url; do printf '  %-8s %s (%s)\n' "${type^}:" "$url" "$code"; done < "$f"
  has_service rabbitmq && echo "  RabbitMQ: http://localhost:$((PORT + 20000))   (guest / guest)"
  return 0
}
