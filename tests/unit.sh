#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2030,SC2031
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$TESTS_DIR")"
source "$TESTS_DIR/lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export PHPBOX_CONF=/dev/null PHPBOX_BOXES_DIR="$TMP/boxes" NO_COLOR=1
mkdir -p "$PHPBOX_BOXES_DIR"

# shellcheck source=../phpbox
source "$ROOT_DIR/phpbox"
set +eu
BASE_PORT=45000

section "Command line"
check "help exits 0" "$ROOT_DIR/phpbox" help
contains "help lists commands" "$("$ROOT_DIR/phpbox" help)" "create <platform> <version>"
contains "help lists platforms" "$("$ROOT_DIR/phpbox" help)" "Platforms: laravel magento mageos prestashop shopware symfony woocommerce"
check_fails "unknown command exits 1" "$ROOT_DIR/phpbox" nope
check_fails "create without arguments fails" "$ROOT_DIR/phpbox" create
check_fails "info of a missing box fails" "$ROOT_DIR/phpbox" info missing

section "Options"
eq "parse_options reads all shared options" \
  "$(parse_options --name shop --php 8.3 --lang en --branch dev --redis --node; echo "$OPT_NAME|$OPT_PHP|$SHOP_LANG|$OPT_BRANCH|$SERVICES")" \
  "shop|8.3|en|dev|redis node"
eq "a service flag is added once" "$(parse_options --redis --redis; echo "$SERVICES")" "redis"
eq "a service flag takes an image tag" "$(parse_options --redis:7.4-alpine --node; echo "$SERVICES")" "redis:7.4-alpine node"
eq "a later tag replaces the earlier one" "$(parse_options --redis --node --redis:7.4-alpine; echo "$SERVICES")" "redis:7.4-alpine node"
eq "a flag without a tag keeps the tag" "$(parse_options --redis:7.4-alpine --redis; echo "$SERVICES")" "redis:7.4-alpine"
check_fails "an invalid tag stops" bash -c "source '$ROOT_DIR/phpbox'; parse_options --redis:7/4"
eq "service_names drops tags" "$(SERVICES="redis:7.4-alpine node"; service_names)" "redis node"
eq "service_tags gives compose variables" "$(SERVICES="redis:7.4-alpine node opensearch:2.12.0"; service_tags | paste -sd' ')" "REDIS_TAG=7.4-alpine OPENSEARCH_TAG=2.12.0"
eq "service_default sets only a missing tag" \
  "$(SERVICES="redis node:14-alpine"; service_default redis 6.2-alpine; service_default node 22-alpine; service_default valkey 8.1-alpine; echo "$SERVICES")" \
  "redis:6.2-alpine node:14-alpine"

section "Magento services"
mage() { load_platform magento; SERVICES="$2"; _mage_services "$1" 4; echo "$DB_IMAGE|$SEARCH|$SERVICES|$(_mage_engine)"; }
eq "2.4.5 uses Elasticsearch 7 and Redis 6.2" "$(mage 2.4.5 "redis")" "mariadb:10.4|elasticsearch|redis:6.2-alpine elasticsearch:7.17.25|elasticsearch7"
eq "2.4.7 uses OpenSearch 2.12 and RabbitMQ 3.13" "$(mage 2.4.7 "rabbitmq")" "mariadb:10.6|opensearch|rabbitmq:3.13-management-alpine opensearch:2.12.0|opensearch"
eq "2.4.9 uses Valkey 9" "$(mage 2.4.9 "valkey")" "mariadb:11.4|opensearch|valkey:9.0-alpine opensearch:2.19.1|opensearch"
eq "an explicit tag wins over the default" "$(mage 2.4.7 "redis:7.4-alpine")" "mariadb:10.6|opensearch|redis:7.4-alpine opensearch:2.12.0|opensearch"
eq "elasticsearch 8 selects elasticsearch8" "$(mage 2.4.7 "elasticsearch:8.1.0")" "mariadb:10.6|elasticsearch|elasticsearch:8.1.0|elasticsearch8"
eq "elasticsearch without a tag on 2.4.6 stays on 7" "$(mage 2.4.6 "elasticsearch")" "mariadb:10.6|elasticsearch|elasticsearch:7.17.25|elasticsearch7"
check_fails "unknown option stops" bash -c "source '$ROOT_DIR/phpbox'; parse_options --nope"
eq "platform option --wp reaches p_option" "$(load_platform woocommerce; parse_options --wp 6.8.3; echo "$OPT_WP")" "6.8.3"

section "Addresses"
eq "shop_url on port 443" "$(SHOP_HOST=a.localhost HTTPS_PORT=443; shop_url)" "https://a.localhost"
eq "shop_url on another port" "$(SHOP_HOST=a.localhost HTTPS_PORT=18443; shop_url)" "https://a.localhost:18443"
eq "shop_locale pl" "$(SHOP_LANG=pl; shop_locale)" "pl_PL"
eq "shop_locale en" "$(SHOP_LANG=en; shop_locale)" "en_US"
eq "shop_locale cs" "$(SHOP_LANG=cs; shop_locale)" "cs_CZ"

section "Box files"
check_fails "name with capitals and _ is rejected" bash -c "source '$ROOT_DIR/phpbox'; init_env Bad_Name"
eq "init_env sets host, database and ports" \
  "$(init_env shop-1; echo "$SHOP_HOST|$DB_NAME|$PORT|$DB_PORT")" "shop-1.localhost|shop_1|45000|55000"
mkdir -p "$PHPBOX_BOXES_DIR/used" && printf 'PORT=45000\nDB_PORT=55000\n' > "$PHPBOX_BOXES_DIR/used/.env"
eq "next_port skips a port used by another box" "$(next_port)" "45001"
rm -rf "$PHPBOX_BOXES_DIR/used"
eq "save_env and load_env keep the values" "$(
  load_platform woocommerce; init_env roundtrip
  VERSION=10.1.0 PHP_VERSION=8.3 DB_IMAGE=mariadb:11.4 KIND=fresh WP_VERSION=6.8.3 SERVICES="redis"
  save_env >/dev/null
  unset VERSION PHP_VERSION WP_VERSION SERVICES
  load_env roundtrip
  echo "$PLATFORM|$VERSION|$PHP_VERSION|$WP_VERSION|$SERVICES|$KIND"
)" "woocommerce|10.1.0|8.3|6.8.3|redis|fresh"
check_fails "save_env rejects PHP without an image" bash -c "source '$ROOT_DIR/phpbox'; load_platform woocommerce; init_env php74; PHP_VERSION=7.4; save_env"
mkdir -p "$TMP/home/.ssh" "$PHPBOX_BOXES_DIR/ssh"
eq "write_ssh_override mounts ~/.ssh without an agent" \
  "$(NAME=ssh HOME="$TMP/home" SSH_AUTH_SOCK=""; write_ssh_override; cat "$PHPBOX_BOXES_DIR/ssh/compose.yml")" \
  "$(printf 'services:\n  php:\n    volumes:\n      - %s/home/.ssh:%s/home/.ssh:ro' "$TMP" "$TMP")"

section "Database dumps"
eq "dump_fix converts MySQL 8 collations" "$(echo 'COLLATE=utf8mb4_0900_ai_ci' | dump_fix)" "COLLATE=utf8mb4_unicode_ci"
eq "dump_fix removes DEFINER" "$(echo 'CREATE DEFINER=`root`@`%` TRIGGER t' | dump_fix)" "CREATE  TRIGGER t"
eq "dump_fix removes MySQL 8 version comments" "$(echo 'a /*!80016 DEFAULT ENCRYPTION=N */ b' | dump_fix)" "a  b"
eq "dump_fix removes GTID_PURGED" "$(printf 'SET @@GLOBAL.GTID_PURGED=/*!80000 */\n  "x:1";\nnext\n' | dump_fix)" "next"
eq "dump_decompress reads .gz" "$(echo hello | gzip | dump_decompress dump.sql.gz)" "hello"
eq "dump_decompress passes .sql" "$(echo hello | dump_decompress dump.sql)" "hello"

section "Versions (src/versions.py)"
PS_API='[
  {"version": "1.7.8.10", "php_min_version": "5.6", "php_max_version": "7.4", "zip_download_url": "u1"},
  {"version": "8.2.0", "php_min_version": "7.2", "php_max_version": "8.1", "zip_download_url": "u2"},
  {"version": "8.2.1", "php_min_version": "7.2", "php_max_version": "8.1", "zip_download_url": "u3"},
  {"version": "9.0.0", "php_min_version": "8.1", "php_max_version": "8.4", "zip_download_url": "u4"},
  {"version": "9.1.0-beta.1", "php_min_version": "8.1", "php_max_version": "8.5", "zip_download_url": "u5"}]'
eq "PrestaShop prefix picks the newest patch" "$(versions_query prestashop resolve 8 <<<"$PS_API")" "8.2.1 8.1 8.2.1 u3"
eq "PrestaShop latest skips beta" "$(versions_query prestashop resolve latest <<<"$PS_API")" "9.0.0 8.4 9.0.0 u4"
check_fails "PrestaShop 1.7 has no PHP 8 image" versions_query prestashop resolve 1.7 <<<"$PS_API"
WC_API='{"requires_php": "8.1", "versions": {"9.9.0": "a", "10.1.0": "b", "10.2.0-rc.1": "c", "trunk": "d"}}'
eq "WooCommerce latest skips rc and trunk" "$(versions_query woocommerce resolve latest <<<"$WC_API")" "10.1.0 8.5 10.1.0 b"
MAGE_P2='{"packages": {"magento/product-community-edition": [
  {"version": "2.4.8-p1", "require": {"php": "~8.2.0||~8.3.0||~8.4.0"}},
  {"version": "2.4.7-p4", "require": {"php": "~8.1.0||~8.2.0||~8.3.0"}}]}}'
eq "Magento 2.4.7 resolves to -p4 with PHP 8.3" \
  "$(versions_query composer resolve magento/product-community-edition 2.4.7 <<<"$MAGE_P2")" "2.4.7-p4 8.3 2.4.7-p4 -"
SKELETON_P2='{"packages": {"vendor/skeleton": [
  {"version": "6.5.0.0", "require": {"php": ">=8.1"}},
  {"version": "v6.7.15.1", "require": {"php": ">=8.2"}},
  {"version": "v6.6.10.29", "require": {"php": ">=8.2"}}]}}'
eq "latest compares versions with a v prefix" \
  "$(versions_query composer resolve vendor/skeleton latest <<<"$SKELETON_P2")" "v6.7.15.1 8.5 v6.7.15.1 -"
LOCK='{"packages": [{"name": "magento/product-community-edition", "version": "2.4.6-p3", "require": {"php": "~8.1.0||~8.2.0"}}]}'
eq "composer.lock gives version and PHP" "$(versions_query lock resolve <<<"$LOCK")" "2.4.6-p3 8.2 2.4.6-p3 -"
eq "config.platform.php wins in composer.lock" "$(versions_query lock resolve 8.1.27 <<<"$LOCK")" "2.4.6-p3 8.1 2.4.6-p3 -"
LOCK_FW='{"packages": [{"name": "magento/framework", "version": "103.0.7-p3", "require": {"php": "~8.1.0||~8.2.0||~8.3.0"}}]}'
eq "magento/framework 103.0.7 maps to 2.4.7" "$(versions_query lock resolve <<<"$LOCK_FW")" "103.0.7-p3 8.3 2.4.7-p3 -"
eq "composer.json require.php" "$(versions_query project resolve <<<'{"require": {"php": ">=8.1"}}')" "8.5"
eq "composer.json config.platform.php" "$(versions_query project resolve <<<'{"config": {"platform": {"php": "8.2.4"}}}')" "8.2"
check_fails "composer.json for PHP 7 exits with an error" versions_query project resolve <<<'{"require": {"php": "^7.4"}}'

section "Composer auth (src/composer_auth.py)"
eq "no keys and no auth.json give an empty value" "$(HOME="$TMP/empty"; composer_auth)" ""
eq "Magento keys go to http-basic" \
  "$(HOME="$TMP/empty" MAGENTO_PUBLIC_KEY=pub MAGENTO_PRIVATE_KEY=priv; composer_auth)" \
  '{"http-basic": {"repo.magento.com": {"username": "pub", "password": "priv"}}}'
mkdir -p "$TMP/auth/.composer" && echo '{"github-oauth": {"github.com": "old"}}' > "$TMP/auth/.composer/auth.json"
eq "GITHUB_TOKEN overrides the host auth.json" "$(HOME="$TMP/auth" GITHUB_TOKEN=new; composer_auth)" '{"github-oauth": {"github.com": "new"}}'

section "Platforms"
for p in $(platforms); do
  missing=$(
    load_platform "$p"
    for v in P_TITLE P_SHORT; do [[ -n "${!v:-}" ]] || echo "$v"; done
    for f in p_resolve p_install p_versions p_info p_snapshot_excludes p_clear_cache; do declare -F "$f" >/dev/null || echo "$f"; done
    [[ -f "$P_NGINX_CONF" ]] || echo "nginx.conf"
  )
  eq "$p defines the required variables, functions and nginx.conf" "$missing" ""
done

section "Code quality"
for f in "$ROOT_DIR/phpbox" "$ROOT_DIR"/src/*.sh "$ROOT_DIR"/platforms/*/*.sh "$ROOT_DIR"/tests/*.sh; do
  check "bash syntax: ${f#"$ROOT_DIR"/}" bash -n "$f"
done
for f in "$ROOT_DIR"/src/*.py; do
  check "python syntax: ${f#"$ROOT_DIR"/}" python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$f"
done
shellcheck_files=(phpbox src/*.sh platforms/*/platform.sh platforms/magento/magento.sh)
if command -v shellcheck >/dev/null; then
  check "shellcheck (warnings)" bash -c "cd '$ROOT_DIR' && shellcheck -x -s bash -S warning ${shellcheck_files[*]}"
elif docker image inspect koalaman/shellcheck:v0.10.0 >/dev/null 2>&1; then
  check "shellcheck (warnings)" docker run --rm -v "$ROOT_DIR:/mnt" -w /mnt koalaman/shellcheck:v0.10.0 -x -s bash -S warning "${shellcheck_files[@]}"
else
  skip "shellcheck" "install shellcheck or: docker pull koalaman/shellcheck:v0.10.0"
fi

summary
