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
contains "help lists add and service" "$("$ROOT_DIR/phpbox" help)" "service add|remove <name> <svc>"
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
mage() { load_platform magento; SERVICES="$2"; _mage_services "$1" 3; echo "$DB_IMAGE|$SEARCH|$SERVICES|$(_mage_engine)"; }
eq "2.4.3 uses Elasticsearch 7 and Redis 6.0" "$(mage 2.4.3-p3 "redis")" "mariadb:10.4.34|elasticsearch|redis:6.0-alpine elasticsearch:7.17.25|elasticsearch7"
check_fails "2.4.3 with OpenSearch stops" bash -c "source '$ROOT_DIR/phpbox'; load_platform magento; SERVICES=opensearch; _mage_services 2.4.3 3"
check_fails "2.4.2 is not supported" bash -c "source '$ROOT_DIR/phpbox'; load_platform magento; _mage_services 2.4.2 3"
eq "2.4.5 uses Elasticsearch 7 and Redis 6.2" "$(mage 2.4.5 "redis")" "mariadb:10.4.34|elasticsearch|redis:6.2-alpine elasticsearch:7.17.25|elasticsearch7"
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
eq "init_env puts the code in boxes/<name>/<name>" "$(init_env code-dir; echo "$WWW_DIR")" "$PHPBOX_BOXES_DIR/code-dir/code-dir"
mkdir -p "$PHPBOX_BOXES_DIR/legacy/www"
eq "set_www_dir keeps www/ of an older box" "$(NAME=legacy; set_www_dir; echo "$WWW_DIR")" "$PHPBOX_BOXES_DIR/legacy/www"
rm -rf "$PHPBOX_BOXES_DIR/legacy"
check_fails "init_env rejects the name of a box subdirectory" init_env snapshot
eq "save_env and load_env keep the values" "$(
  load_platform woocommerce; init_env roundtrip
  VERSION=10.1.0 PHP_VERSION=8.3 DB_IMAGE=mariadb:11.4 KIND=fresh WP_VERSION=6.8.3 SERVICES="redis"
  save_env >/dev/null
  unset VERSION PHP_VERSION WP_VERSION SERVICES
  load_env roundtrip
  echo "$PLATFORM|$VERSION|$PHP_VERSION|$WP_VERSION|$SERVICES|$KIND"
)" "woocommerce|10.1.0|8.3|6.8.3|redis|fresh"
eq "exec runs the command in php without a TTY" \
  "$(compose() { echo "$*"; }; cmd_exec roundtrip bin/magento cache:flush)" "exec -T php bin/magento cache:flush"
eq "exec --service picks the container" \
  "$(compose() { echo "$*"; }; cmd_exec roundtrip --service node npm -v)" "exec -T node npm -v"
check_fails "exec without a command fails" bash -c "source '$ROOT_DIR/phpbox'; compose() { :; }; cmd_exec roundtrip"
check_fails "exec --service without a command fails" bash -c "source '$ROOT_DIR/phpbox'; compose() { :; }; cmd_exec roundtrip --service node"
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

section "Project directory (add)"
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/docker" <<'SH'
#!/bin/sh
case "$*" in
  *"ps -a --format json"*) printf '%s\n' "${FAKE_PS:-}" ;;
  *) printf '%s\n' "$@" | grep '\.yml$'; env | grep '^VARNISH_VCL=' ;;
esac
SH
chmod +x "$TMP/fakebin/docker"
mkdir -p "$TMP/project/.phpbox/hooks" "$TMP/project/.phpbox/nginx"
eq "init_env with a code directory sets CODE_DIR and WWW_DIR" \
  "$(init_env ext "$TMP/project"; echo "$CODE_DIR|$WWW_DIR")" "$TMP/project|$TMP/project"
eq "init_env without a code directory clears CODE_DIR" "$(CODE_DIR=/x; init_env plain; echo "${CODE_DIR}|$WWW_DIR")" "|$PHPBOX_BOXES_DIR/plain/plain"
eq "save_env and load_env keep CODE_DIR and DB_STRIP" "$(
  load_platform symfony; init_env ext "$TMP/project"
  VERSION=- PHP_VERSION=8.3 DB_IMAGE=mariadb:11.4 KIND=project DB_STRIP="@log x_*"
  save_env >/dev/null
  unset CODE_DIR DB_STRIP WWW_DIR
  load_env ext
  echo "$CODE_DIR|$WWW_DIR|$DB_STRIP"
)" "$TMP/project|$TMP/project|@log x_*"
eq "a box without CODE_DIR keeps boxes/<name>/<name>" "$(load_env roundtrip; echo "$WWW_DIR")" "$PHPBOX_BOXES_DIR/roundtrip/roundtrip"
check_fails "add of a missing directory fails" "$ROOT_DIR/phpbox" add symfony "$TMP/missing"
check_fails "add of a directory used by another box fails" bash -c "source '$ROOT_DIR/phpbox'; BASE_PORT=45100; cmd_add symfony '$TMP/project' --name other"
contains "list shows the project directory box" "$(cmd_list)" "ext "
eq "compose loads .phpbox and box files after the services" "$(
  PATH="$TMP/fakebin:$PATH"
  load_env ext; touch "$TMP/project/.phpbox/compose.yml" "$TMP/project/.phpbox/compose.local.yml" "$PHPBOX_BOXES_DIR/ext/compose.dev.yml"
  SERVICES=redis; compose config | grep -v VARNISH | sed "s#$ROOT_DIR#R#; s#$TMP#T#" | paste -sd' '
)" "R/docker/compose.yml R/docker/services/redis.yml T/project/.phpbox/compose.yml T/project/.phpbox/compose.local.yml T/boxes/ext/compose.dev.yml"
rm -f "$TMP/project/.phpbox/compose.yml" "$TMP/project/.phpbox/compose.local.yml" "$PHPBOX_BOXES_DIR/ext/compose.dev.yml"
eq "compose passes the box VCL when it exists" "$(
  PATH="$TMP/fakebin:$PATH"
  load_env ext; { compose config; touch "$PHPBOX_BOXES_DIR/ext/varnish.vcl"; compose config; rm "$PHPBOX_BOXES_DIR/ext/varnish.vcl"; } | grep VARNISH | sed "s#$ROOT_DIR#R#; s#$TMP#T#"
)" "VARNISH_VCL=R/docker/varnish/default.vcl
VARNISH_VCL=T/boxes/ext/varnish.vcl"

section "Hooks"
printf 'echo project\n' > "$TMP/project/.phpbox/hooks/post-import"
mkdir -p "$PHPBOX_BOXES_DIR/ext/hooks" && printf 'echo box\n' > "$PHPBOX_BOXES_DIR/ext/hooks/post-import"
eq "run_hooks runs the project hook, then the box hook, in php with the event" "$(
  php_run() { echo "$*|$(cat)"; }
  load_env ext; run_hooks post-import -e X=1 | grep -v '→' | sed "s#https://ext.localhost#URL#"
)" "-e PHPBOX_EVENT=post-import -e PHPBOX_NAME=ext -e SHOP_URL=URL -e SERVICES= -e X=1|echo project
-e PHPBOX_EVENT=post-import -e PHPBOX_NAME=ext -e SHOP_URL=URL -e SERVICES= -e X=1|echo box"
eq "run_hooks without hook files does nothing" "$(php_run() { echo called; }; load_env ext; run_hooks post-start)" ""
check_fails "a failing hook stops" bash -c "source '$ROOT_DIR/phpbox'; php_run() { cat >/dev/null; return 1; }; load_env ext; run_hooks post-import"

section "Services of a box"
eq "remove_service drops the service with its tag" "$(SERVICES="redis:7.4-alpine node opensearch"; remove_service redis; echo "$SERVICES")" "node opensearch"
eq "service add saves SERVICES, applies them and runs the platform hook" "$(
  box_up() { echo "up $*"; }; run_hooks() { echo "hook $*"; }; p_service_changed() { echo "platform $*"; }
  cmd_service add ext varnish 2>&1 | grep -v '✔\|→'; load_env ext; echo "$SERVICES"
)" "up --remove-orphans
platform add varnish
hook post-service-change -e PHPBOX_ACTION=add -e PHPBOX_SERVICE=varnish
varnish"
eq "service remove drops it again" "$(
  box_up() { :; }; run_hooks() { :; }
  cmd_service remove ext varnish >/dev/null; load_env ext; echo "[$SERVICES]"
)" "[]"
check_fails "service remove of an unused service fails" bash -c "source '$ROOT_DIR/phpbox'; cmd_service remove ext redis"
check_fails "service add of an unknown service fails" bash -c "source '$ROOT_DIR/phpbox'; cmd_service add ext nope"
check_fails "the search engine cannot be removed" bash -c "source '$ROOT_DIR/phpbox'; box_up() { :; }; load_env ext; SEARCH=opensearch; SERVICES=opensearch; save_env >/dev/null; printf 'SEARCH=opensearch\n' >> '$PHPBOX_BOXES_DIR/ext/.env'; cmd_service remove ext opensearch"
sed -i '/^SEARCH=/d; s/^SERVICES=.*/SERVICES=/' "$PHPBOX_BOXES_DIR/ext/.env"

section "JSON output"
eq "list --json gives a valid array with the project directory" "$(
  docker() { echo phpbox-ext; }
  cmd_list --json | python3 -I -c 'import json, sys; b = {x["name"]: x for x in json.load(sys.stdin)}; e = b["ext"]; print(e["status"], e["external_code"], e["code_dir"] == sys.argv[1], e["database"]["port"] > 0, b["roundtrip"]["status"])' "$TMP/project"
)" "running True True True stopped"
eq "info --json adds containers from compose ps" "$(
  docker() { echo phpbox-ext; }; PATH="$TMP/fakebin:$PATH"; export FAKE_PS='{"Service":"php","Name":"phpbox-ext-php-1","Image":"x","State":"running"}'
  cmd_info ext --json | python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(d["containers"][0]["service"], d["containers"][0]["state"], d["platform"])'
)" "php running symfony"
eq "info --json reads a compose ps array too" "$(
  docker() { :; }; PATH="$TMP/fakebin:$PATH"; export FAKE_PS='[{"Service":"db","State":"exited"}]'
  cmd_info ext --json | python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(d["containers"][0]["service"], d["status"])'
)" "db stopped"
eq "capabilities lists the features" "$(cmd_capabilities | python3 -I -c 'import json, sys; print(" ".join(json.load(sys.stdin)["capabilities"]))')" \
  "add db-import-strip hooks info-json list-json nginx-includes project-config service"

section "Database dumps (strip)"
eq "strip_patterns expands Magento groups and keeps tables" "$(load_platform magento; strip_patterns "@sessions @quotes custom_*")" "session,quote,quote_*,custom_*"
check_fails "strip_patterns stops on an unknown group" bash -c "source '$ROOT_DIR/phpbox'; load_platform magento; strip_patterns @nope"
check_fails "strip_patterns stops on a group of a platform without groups" bash -c "source '$ROOT_DIR/phpbox'; load_platform symfony; strip_patterns @log"
DUMP=$'CREATE TABLE `session` (id int);\nINSERT INTO `session` VALUES (1),(2);\nINSERT INTO `quote` VALUES\n(1),\n(2);\nINSERT INTO `quote_item` (`a`) VALUES (1);\nINSERT INTO `quotes_x` VALUES (1);\nINSERT INTO `core_config_data` VALUES (1);'
eq "dump_strip drops single-line, multi-line and column-list INSERTs of matching tables" "$(dump_strip "session,quote,quote_*" <<<"$DUMP")" \
  $'CREATE TABLE `session` (id int);\nINSERT INTO `quotes_x` VALUES (1);\nINSERT INTO `core_config_data` VALUES (1);'
eq "dump_strip without patterns passes the dump" "$(dump_strip "" <<<"$DUMP")" "$DUMP"
check_fails "db-import with an unknown option fails" bash -c "source '$ROOT_DIR/phpbox'; cmd_db_import ext /dev/null --nope"

section "nginx"
for f in "$ROOT_DIR"/platforms/*/nginx.conf; do
  eq "${f#"$ROOT_DIR"/} includes the service, box and project files" \
    "$(grep -c 'include /etc/nginx/services/\*.server.conf;\|include /etc/nginx/phpbox/\*.server.conf;\|include /var/www/html/.phpbox/nginx/\*.server.conf;\|include /etc/nginx/phpbox/\*.http.conf;\|include /var/www/html/.phpbox/nginx/\*.http.conf;' "$f")" "5"
done

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
eq "composer.lock of Magento 2.4.3 gives PHP 7.4" \
  "$(versions_query lock resolve <<<'{"packages": [{"name": "magento/product-community-edition", "version": "2.4.3-p3", "require": {"php": "~7.3.0||~7.4.0"}}]}')" "2.4.3-p3 7.4 2.4.3-p3 -"
check_fails "composer.json for PHP 7.2 exits with an error" versions_query project resolve <<<'{"require": {"php": "~7.2.0"}}'
mkdir -p "$TMP/lock"
eq "composer.lock from Composer 2.2 selects composer-2.2" \
  "$(WWW_DIR="$TMP/lock"; echo '{"plugin-api-version": "2.2.0"}' > "$WWW_DIR/composer.lock"; composer_detect; echo "$COMPOSER_PHAR")" "composer-2.2"
eq "composer.lock from Composer 2.6 keeps the latest composer" \
  "$(WWW_DIR="$TMP/lock"; echo '{"plugin-api-version": "2.6.0"}' > "$WWW_DIR/composer.lock"; composer_detect; echo "$COMPOSER_PHAR")" ""
eq "no composer.lock keeps the latest composer" "$(WWW_DIR="$TMP/none"; composer_detect; echo "$COMPOSER_PHAR")" ""

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

section "Update check"
UPDATE_FILE="$TMP/update-check"
git -C "$ROOT_DIR" rev-parse HEAD > "$UPDATE_FILE"
check_fails "no notice when HEAD has the upstream commit" update_available
printf '%040d\n' 0 | tr 0 a > "$UPDATE_FILE"
check "notice when the upstream commit is unknown locally" update_available
echo "<html>" > "$UPDATE_FILE"
check_fails "no notice for an invalid cache" update_available
: > "$UPDATE_FILE"
check_fails "no notice for an empty cache" update_available
eq "UPDATE_CHECK=0 prints nothing" "$(UPDATE_CHECK=0 update_notice 2>&1)" ""

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
