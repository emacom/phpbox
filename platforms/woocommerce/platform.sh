# shellcheck shell=bash disable=SC2034
P_TITLE="WooCommerce"
P_SHORT="wc"
P_ENV_KEYS="WP_VERSION"
P_CRON="wp cron event run --due-now --quiet"
WC_API="https://api.wordpress.org/plugins/info/1.0/woocommerce.json"
WP_API="https://api.wordpress.org/core/version-check/1.7/"
WC_PHP_MAX="8.4"
OPT_WP=""

p_option() {
  case "$1" in
    --wp) OPT_WP="$2" ;;
    *) return 1 ;;
  esac
}

_wp_latest() { curl -fsSL "$WP_API" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["offers"][0]["current"])'; }

# Make the WordPress HTTP API trust the phpbox CA bundle instead of wp-includes/certificates.
_wp_ca_plugin() {
  mkdir -p "$WWW_DIR/wp-content/mu-plugins"
  cat > "$WWW_DIR/wp-content/mu-plugins/phpbox-ca.php" <<'PHP'
<?php
if (is_readable('/cache/certs/ca-bundle.pem')) {
    add_filter('http_request_args', function ($args) {
        $args['sslcertificates'] = '/cache/certs/ca-bundle.pem';
        return $args;
    });
}
PHP
}

p_resolve() {
  local out base php
  out=$(curl -fsSL "$WC_API" | versions_query woocommerce resolve "$1") \
    || die "Version '$1' not found (phpbox versions woocommerce)"
  read -r VERSION php base DOWNLOAD_URL <<<"$out"
  PHP_VERSION=$(printf '%s\n%s\n' "$php" "$WC_PHP_MAX" | sort -V | head -1)
  WP_VERSION="${OPT_WP:-$(_wp_latest)}"
  DB_IMAGE="mariadb:11.4"
}

p_versions() { curl -fsSL "$WC_API" | versions_query woocommerce list | head -40; }

p_install() {
  php_run \
    -e WP_VERSION="$WP_VERSION" -e WC_VERSION="$VERSION" -e WP_URL="$(shop_url)" \
    -e WP_LOCALE="$(shop_locale)" -e WC_COUNTRY="${SHOP_COUNTRY^^}" -e WC_CURRENCY="$SHOP_CURRENCY" -e WP_TZ="$SHOP_TZ" <<'SH'
set -euo pipefail
echo "→ WordPress $WP_VERSION ($WP_LOCALE)…"
wp core download --version="$WP_VERSION" --locale="$WP_LOCALE"
wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" --dbhost=db --locale="$WP_LOCALE" --skip-check
wp core install --url="$WP_URL" --title="WooCommerce $WC_VERSION" --admin_user="$ADMIN_USER" \
  --admin_password="$ADMIN_PASSWORD" --admin_email="$ADMIN_EMAIL" --skip-email
wp option update timezone_string "$WP_TZ"
wp rewrite structure '/%postname%/'
wp plugin delete --all
echo "→ WooCommerce $WC_VERSION…"
wp plugin install woocommerce --version="$WC_VERSION" --activate
[[ "$WP_LOCALE" == en_US ]] || wp language plugin install woocommerce "$WP_LOCALE" || echo "No WooCommerce translation for $WP_LOCALE"
wp option update woocommerce_default_country "$WC_COUNTRY"
wp option update woocommerce_currency "$WC_CURRENCY"
wp option update woocommerce_onboarding_profile '{"skipped":true}' --format=json
wp eval 'WC_Install::create_pages();'
echo "→ Installed"
SH
  _wp_ca_plugin
}

# Print the table prefix detected from the options table name.
_wp_prefix() {
  local table
  table=$(db_exec -N "$DB_NAME" -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME LIKE '%options' ORDER BY LENGTH(TABLE_NAME) LIMIT 1")
  [[ -n "$table" ]] || die "Database has no options table"
  echo "${table%options}"
}

p_clone_detect() {
  local core="$WWW_DIR/wp-includes/version.php" wc="$WWW_DIR/wp-content/plugins/woocommerce/woocommerce.php" out php
  [[ -d "$WWW_DIR/wp-content" ]] || die "No wp-content in repository; WordPress root expected"
  if [[ -f "$core" ]]; then
    WP_VERSION=$(sed -nE "s/^\\\$wp_version = '([^']+)'.*/\\1/p" "$core")
  else
    WP_VERSION="${OPT_WP:-$(_wp_latest)}"
  fi
  VERSION=""
  [[ -f "$wc" ]] && VERSION=$(sed -nE 's/^[ *]*Version: *([^ ]+).*/\1/p' "$wc" | head -1)
  VERSION="${VERSION:-$(git -C "$WWW_DIR" describe --tags --always 2>/dev/null || echo "-")}"
  PHP_VERSION="$WC_PHP_MAX"
  if [[ -f "$wc" ]] && out=$(curl -fsSL "$WC_API" | versions_query woocommerce resolve "$VERSION"); then
    read -r _ php _ _ <<<"$out"
    PHP_VERSION=$(printf '%s\n%s\n' "$php" "$WC_PHP_MAX" | sort -V | head -1)
  fi
  DB_IMAGE="mariadb:11.4"
}

# Install composer dependencies and WordPress core when the repository has only wp-content.
p_project_install() {
  {
    echo 'set -euo pipefail'
    if [[ -f "$WWW_DIR/composer.json" ]]; then
      echo 'echo "→ composer install…"'
      echo 'composer install --no-interaction --no-progress'
    fi
    if [[ ! -f "$WWW_DIR/wp-includes/version.php" ]]; then
      echo 'echo "→ WordPress $WP_VERSION core…"'
      echo 'wp core download --version="$WP_VERSION" --skip-content'
    fi
  } | COMPOSER_AUTH="$(composer_auth)" php_run -e COMPOSER_AUTH -e WP_VERSION="$WP_VERSION"
}

# Rewrite wp-config.php, URLs, mail plugins and the admin account of an imported database for local use.
p_after_import() {
  local prefix
  _wp_ca_plugin
  prefix=$(_wp_prefix)
  [[ "$prefix" == wp_ ]] || log "Table prefix: $prefix"
  log "wp-config.php, URLs, admin account…"
  php_run -e WP_PREFIX="$prefix" -e NEW_URL="$(shop_url)" <<'SH'
set -euo pipefail
wpc() { wp --skip-plugins --skip-themes "$@"; }
if [[ -f wp-config.php ]]; then
  cp wp-config.php "wp-config.php.$(date +%s).orig"
  wpc config set DB_NAME "$DB_NAME" --quiet
  wpc config set DB_USER "$DB_USER" --quiet
  wpc config set DB_PASSWORD "$DB_PASS" --quiet
  wpc config set DB_HOST db --quiet
  wpc config set table_prefix "$WP_PREFIX" --type=variable --quiet
  for c in WP_HOME WP_SITEURL; do
    if wpc config has "$c"; then wpc config delete "$c" --quiet; fi
  done
else
  wpc config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" --dbhost=db --dbprefix="$WP_PREFIX" --skip-check
fi
wpc config set WP_ENVIRONMENT_TYPE local --quiet
old=$(wpc option get home)
old="${old#*://}"; old="${old%%/*}"
if [[ -n "$old" ]]; then
  for scheme in https http; do
    [[ "$scheme://$old" == "$NEW_URL" ]] && continue
    echo "→ $scheme://$old → $NEW_URL"
    wpc search-replace "$scheme://$old" "$NEW_URL" --all-tables --skip-columns=guid --quiet
  done
fi
wpc option update home "$NEW_URL" --quiet
wpc option update siteurl "$NEW_URL" --quiet
for p in wp-mail-smtp post-smtp easy-wp-smtp fluent-smtp smtp-mailer; do
  if wpc plugin is-active "$p"; then wpc plugin deactivate "$p" --quiet; fi
done
if wpc user get "$ADMIN_USER" --field=ID >/dev/null 2>&1; then
  wpc user update "$ADMIN_USER" --user_pass="$ADMIN_PASSWORD" --role=administrator --skip-email --quiet
else
  wpc user create "$ADMIN_USER" "$ADMIN_EMAIL" --role=administrator --user_pass="$ADMIN_PASSWORD" --quiet \
    || echo "E-mail $ADMIN_EMAIL belongs to another user; log in with the imported account"
fi
wp cache flush >/dev/null
SH
}

# Point a copied database at this environment's host: p_rehost <old-url>
p_rehost() {
  php_run -e OLD_URL="$1" -e NEW_URL="$(shop_url)" <<'SH'
set -euo pipefail
wp search-replace "$OLD_URL" "$NEW_URL" --all-tables --skip-columns=guid --quiet
wp cache flush >/dev/null
SH
}

p_snapshot_excludes() { echo "wp-content/cache wp-content/upgrade"; }

p_clear_cache() { php_run <<<'wp cache flush >/dev/null'; }

p_info() {
  cat <<INFO
  Shop:    $(shop_url)   (WordPress $WP_VERSION)
  Admin:   $(shop_url)/wp-admin   ($ADMIN_USER / $ADMIN_PASSWORD)
INFO
}
