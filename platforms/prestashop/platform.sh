# shellcheck shell=bash disable=SC2034
P_TITLE="PrestaShop"
P_SHORT="ps"
PS_API="https://api.prestashop-project.org/prestashop"
P_ENV_KEYS="PS_ADMIN_DIR"
P_COMPOSE=("$PLATFORM_DIR/prestashop.yml")
PS_ADMIN_DIR="${PS_ADMIN_DIR:-admin-dev}"

p_resolve() {
  local out base
  out=$(curl -fsSL "$PS_API" | versions_query prestashop resolve "$1") \
    || die "Version '$1' with PHP 8.0+ support not found (phpbox versions prestashop)"
  read -r VERSION PHP_VERSION base DOWNLOAD_URL <<<"$out"
  DB_IMAGE="mariadb:10.11"
}

p_versions() { curl -fsSL "$PS_API" | versions_query prestashop list; }

p_install() {
  php_run \
    -e PS_VERSION="$VERSION" -e PS_URL="$DOWNLOAD_URL" -e PS_DOMAIN="$(shop_hostport)" \
    -e PS_LANG="$SHOP_LANG" -e PS_COUNTRY="$SHOP_COUNTRY" -e PS_TZ="$SHOP_TZ" \
    -e PS_ADMIN_DIR="$PS_ADMIN_DIR" <<'SH'
set -euo pipefail
zip="/cache/prestashop-$PS_VERSION.zip"
if [[ ! -s "$zip" ]]; then
  echo "→ Downloading $PS_URL"
  curl -fL --progress-bar -o "$zip.part" "$PS_URL" && mv "$zip.part" "$zip"
fi
echo "→ Extracting…"
tmp=$(mktemp -d)
unzip -q "$zip" prestashop.zip -d "$tmp"
unzip -q -o "$tmp/prestashop.zip" -d /var/www/html
rm -rf "$tmp"
echo "→ CLI installer (1–3 min)…"
php -d memory_limit=-1 -d error_reporting='E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED' install/index_cli.php \
  --domain="$PS_DOMAIN" --ssl=1 \
  --db_server=db --db_name="$DB_NAME" --db_user="$DB_USER" --db_password="$DB_PASS" --prefix=ps_ \
  --name="PrestaShop $PS_VERSION" --language="$PS_LANG" --country="$PS_COUNTRY" --timezone="$PS_TZ" \
  --firstname=Admin --lastname=PhpBox --email="$ADMIN_EMAIL" --password="$ADMIN_PASSWORD"
rm -rf install
adm=$(dirname "$(ls -d admin*/init.php | head -1)")
if [[ "$adm" != "$PS_ADMIN_DIR" ]]; then
  mv "$adm" "$PS_ADMIN_DIR"
  rm -rf var/cache/*
fi
echo "→ Installed"
SH
}

# Print the table prefix detected from the configuration table name.
_ps_prefix() {
  local table
  table=$(db_exec -N "$DB_NAME" -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME LIKE '%configuration' ORDER BY LENGTH(TABLE_NAME) LIMIT 1")
  [[ -n "$table" ]] || die "Database has no configuration table"
  echo "${table%configuration}"
}

# Write the nginx location of a non-default admin directory.
_ps_admin_conf() {
  local f="$BOXES_DIR/$NAME/nginx/admin.conf"
  mkdir -p "$(dirname "$f")"
  if [[ "$PS_ADMIN_DIR" == admin-dev ]]; then
    : > "$f"
  else
    printf 'location /%s/ {\n    try_files $uri $uri/ /%s/index.php$is_args$args;\n}\n' "$PS_ADMIN_DIR" "$PS_ADMIN_DIR" > "$f"
  fi
}

# Point the shop at this environment's host: _ps_domain <table-prefix>
_ps_domain() {
  local p="$1" domain; domain=$(shop_hostport)
  db_exec "$DB_NAME" -e "UPDATE \`${p}shop_url\` SET domain = '$domain', domain_ssl = '$domain';
    UPDATE \`${p}configuration\` SET value = '$domain' WHERE name IN ('PS_SHOP_DOMAIN', 'PS_SHOP_DOMAIN_SSL');"
}

p_clone_detect() {
  local f out
  for f in "$WWW_DIR/src/Core/Version.php" "$WWW_DIR/app/AppKernel.php"; do
    [[ -f "$f" ]] && VERSION=$(sed -nE "s/.*const VERSION = '([^']+)'.*/\1/p" "$f")
    [[ -n "${VERSION:-}" ]] && break
  done
  [[ -n "${VERSION:-}" ]] || die "PrestaShop version not detected in src/Core/Version.php or app/AppKernel.php"
  if out=$(curl -fsSL "$PS_API" | versions_query prestashop resolve "$VERSION"); then
    read -r _ PHP_VERSION _ _ <<<"$out"
  elif [[ -z "$OPT_PHP" ]]; then
    die "PrestaShop $VERSION not found in $PS_API; force --php"
  fi
  for f in "$WWW_DIR"/*/init.php; do
    [[ -d "$(dirname "$f")/themes" ]] && { PS_ADMIN_DIR=$(basename "$(dirname "$f")"); break; }
  done
  DB_IMAGE="mariadb:10.11"
  _ps_admin_conf
}

# Rewrite domain, mail and SSL settings, app/config/parameters.php and the admin account for local use.
p_after_import() {
  local prefix locale
  prefix=$(_ps_prefix)
  locale=$(shop_locale)
  [[ "$prefix" == ps_ ]] || log "Table prefix: $prefix"
  log "Configuring database for $(shop_url)…"
  _ps_domain "$prefix"
  db_exec "$DB_NAME" -e "UPDATE \`${prefix}configuration\` SET value = '0' WHERE name = 'PS_MEDIA_SERVERS';
    UPDATE \`${prefix}configuration\` SET value = '1' WHERE name IN
      ('PS_SSL_ENABLED', 'PS_SSL_ENABLED_EVERYWHERE', 'PS_MAIL_METHOD', 'PS_SHOP_ENABLE');"

  log "app/config/parameters.php, admin account…"
  php_run -e PS_PREFIX="$prefix" -e PS_LOCALE="${locale/_/-}" <<'SH'
set -euo pipefail
php <<'PHP'
<?php
$file = 'app/config/parameters.php';
if (is_file($file)) {
    $config = include $file;
    copy($file, $file . '.' . time() . '.orig');
} else {
    require 'vendor/autoload.php';
    $config = Symfony\Component\Yaml\Yaml::parseFile('app/config/parameters.yml.dist');
    $key = openssl_pkey_new(['private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA]);
    openssl_pkey_export($key, $privateKey);
    $config['parameters'] = array_merge($config['parameters'], [
        'secret' => bin2hex(random_bytes(32)),
        'cookie_key' => bin2hex(random_bytes(32)),
        'cookie_iv' => bin2hex(random_bytes(16)),
        'new_cookie_key' => Defuse\Crypto\Key::createNewRandomKey()->saveToAsciiSafeString(),
        'api_public_key' => openssl_pkey_get_details($key)['key'],
        'api_private_key' => $privateKey,
        'ps_creation_date' => date('Y-m-d'),
        'locale' => getenv('PS_LOCALE'),
    ]);
}
$config['parameters'] = array_merge($config['parameters'], [
    'database_host' => 'db',
    'database_port' => '',
    'database_name' => getenv('DB_NAME'),
    'database_user' => getenv('DB_USER'),
    'database_password' => getenv('DB_PASS'),
    'database_prefix' => getenv('PS_PREFIX'),
]);
file_put_contents($file, '<?php return ' . var_export($config, true) . ';' . PHP_EOL);

$prefix = getenv('PS_PREFIX');
$db = new PDO('mysql:host=db;dbname=' . getenv('DB_NAME'), getenv('DB_USER'), getenv('DB_PASS'));
$db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$hash = password_hash(getenv('ADMIN_PASSWORD'), PASSWORD_BCRYPT);
$update = $db->prepare("UPDATE `{$prefix}employee` SET passwd = ?, active = 1 WHERE email = ?");
$update->execute([$hash, getenv('ADMIN_EMAIL')]);
if ($update->rowCount() === 0) {
    $row = $db->query("SELECT * FROM `{$prefix}employee` WHERE id_profile = 1 ORDER BY id_employee LIMIT 1")->fetch(PDO::FETCH_ASSOC);
    if (!$row) {
        fwrite(STDERR, "No SuperAdmin employee to copy; admin account not created\n");
        exit(0);
    }
    unset($row['id_employee']);
    $row = array_merge($row, ['email' => getenv('ADMIN_EMAIL'), 'passwd' => $hash, 'firstname' => 'Admin', 'lastname' => 'PhpBox', 'active' => 1]);
    $columns = implode(', ', array_map(fn ($c) => "`$c`", array_keys($row)));
    $db->prepare("INSERT INTO `{$prefix}employee` ($columns) VALUES (" . rtrim(str_repeat('?, ', count($row)), ', ') . ')')
        ->execute(array_values($row));
    $id = $db->lastInsertId();
    $db->exec("INSERT INTO `{$prefix}employee_shop` (id_employee, id_shop) SELECT $id, id_shop FROM `{$prefix}shop`");
}
PHP
SH
  _ps_admin_conf
  compose exec -T web nginx -s reload
  p_clear_cache
}

# Point a copied database at this environment's host: p_rehost <old-url>
p_rehost() {
  _ps_domain "$(_ps_prefix)"
  _ps_admin_conf
  compose exec -T web nginx -s reload
  p_clear_cache
}

p_snapshot_excludes() { echo "var/cache var/logs"; }

p_clear_cache() { rm -rf "$WWW_DIR"/var/cache/*; }

p_info() {
  cat <<INFO
  Shop:    $(shop_url)
  Admin:   $(shop_url)/$PS_ADMIN_DIR   ($ADMIN_EMAIL / $ADMIN_PASSWORD)
INFO
}
