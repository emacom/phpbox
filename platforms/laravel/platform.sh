# shellcheck shell=bash disable=SC2034
P_TITLE="Laravel"
P_SHORT="lv"
P_CRON="php artisan schedule:run"
LV_REPO="https://repo.packagist.org"
LV_PACKAGE="laravel/laravel"

_lv_meta() { curl -fsSL "$LV_REPO/p2/$LV_PACKAGE.json"; }

# Point www/.env at the box database, address and Mailpit; create it from .env.example and generate APP_KEY when missing.
_lv_write_env() {
  [[ -f "$WWW_DIR/.env" ]] && cp "$WWW_DIR/.env" "$WWW_DIR/.env.$(date +%s).orig"
  php_run -e LV_URL="$(shop_url)" <<'SH'
set -euo pipefail
[[ -f .env ]] || cp .env.example .env
php <<'PHP'
<?php
$values = [
    'APP_ENV' => 'local',
    'APP_DEBUG' => 'true',
    'APP_URL' => getenv('LV_URL'),
    'DB_CONNECTION' => 'mariadb',
    'DB_HOST' => 'db',
    'DB_PORT' => '3306',
    'DB_DATABASE' => getenv('DB_NAME'),
    'DB_USERNAME' => getenv('DB_USER'),
    'DB_PASSWORD' => getenv('DB_PASS'),
    'MAIL_MAILER' => 'smtp',
    'MAIL_HOST' => 'phpbox-mailpit',
    'MAIL_PORT' => '1025',
    'MAIL_USERNAME' => 'null',
    'MAIL_PASSWORD' => 'null',
];
$env = file_get_contents('.env');
foreach ($values as $key => $value) {
    $line = "$key=$value";
    $pattern = '/^#?\s*' . $key . '=.*$/m';
    $env = preg_match($pattern, $env) ? preg_replace($pattern, $line, $env, 1) : rtrim($env) . "\n$line\n";
}
file_put_contents('.env', $env);
PHP
grep -qE '^APP_KEY=.+' .env || php artisan key:generate --force
SH
}

p_resolve() {
  local query="$1" out
  [[ "$query" == latest ]] || query="v${query#v}"
  out=$(_lv_meta | versions_query composer resolve "$LV_PACKAGE" "$query") \
    || die "Version '$1' not found (phpbox versions laravel)"
  read -r VERSION PHP_VERSION _ _ <<<"$out"
  VERSION="${VERSION#v}"
  DOWNLOAD_URL="-"
  DB_IMAGE="mariadb:11.4"
}

p_versions() { _lv_meta | versions_query composer list "$LV_PACKAGE" | sed -E 's/^v//' | head -40; }

p_install() {
  php_run -e LV_PACKAGE="$LV_PACKAGE" -e LV_VERSION="$VERSION" -e COMPOSER_AUTH="$(composer_auth)" <<'SH'
set -euo pipefail
echo "→ composer create-project $LV_PACKAGE:$LV_VERSION…"
composer create-project --no-interaction --no-progress --no-scripts "$LV_PACKAGE:$LV_VERSION" .
composer run-script post-autoload-dump
SH
  _lv_write_env
  php_run <<'SH'
set -euo pipefail
rm -f database/database.sqlite
php artisan migrate --force
php artisan storage:link
echo "→ Installed"
SH
}

p_project_install() {
  php_run -e COMPOSER_AUTH="$(composer_auth)" <<'SH'
set -euo pipefail
echo "→ composer install…"
composer install --no-interaction --no-progress
SH
  _lv_write_env
}

p_after_import() {
  _lv_write_env
  log ".env points at database $DB_NAME"
  p_clear_cache
}

p_snapshot_excludes() { echo "storage/logs storage/framework/cache/data storage/framework/sessions storage/framework/views"; }

p_clear_cache() { php_run <<<'php artisan optimize:clear'; }

p_info() {
  cat <<INFO
  App:     $(shop_url)
INFO
}
