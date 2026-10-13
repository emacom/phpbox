# Adding a platform

A platform is a `platforms/<name>/` directory. The directory name is the `<platform>` argument of the commands.

| File | Required | Contents |
|---|---|---|
| `platform.sh` | yes | Platform variables and functions, loaded by `load_platform` |
| `nginx.conf` | yes | Configuration of the `web` container |
| `README.md` | yes | Platform description for the user, in English |
| `<name>.yml` | no | Compose overlay from `P_COMPOSE` |

`load_platform` loads `platform.sh` after the box `.env`. The default value of a variable from `P_ENV_KEYS` has the form `X="${X:-default}"`, otherwise it overwrites the value from `.env`.

## Platform variables

| Variable | Required | Meaning |
|---|---|---|
| `P_TITLE` | yes | Name in messages |
| `P_SHORT` | yes | Default box name prefix: `P_SHORT` + version digits |
| `P_ENV_KEYS` | no | Extra variables saved in the box `.env` |
| `P_CRON` | no | Command of the `cron` service, run every 60 s in `/var/www/html` |
| `P_COMPOSE` | no | Array of compose overlays, e.g. a search engine |
| `P_NGINX_CONF` | no | Defaults to `platforms/<name>/nginx.conf` |

## Platform functions

| Function | Required | Called by | Task |
|---|---|---|---|
| `p_resolve <version>` | yes | `create` | Sets `VERSION`, `PHP_VERSION`, `DB_IMAGE`, `DOWNLOAD_URL` |
| `p_install` | yes | `create` | Installs the platform in `www/` via `php_run` |
| `p_versions` | yes | `versions` | Prints available versions |
| `p_info` | yes | `create`, `copy`, `db-import`, `start`, `info` | Prints the shop and admin addresses |
| `p_snapshot_excludes` | yes | `create`, `snapshot`, `reset`, `copy`, `db-import` | Prints paths in `www/` skipped by the snapshot |
| `p_clear_cache` | yes | `reset` | Clears the cache after a snapshot restore |
| `p_option <flag> <value>` | no | `create` | Handles custom flags. Returns 1 for an unknown flag |
| `p_rehost <old-url>` | no | `copy` | Points the copied database at the new address |
| `p_clone_detect` | no | `clone` | Sets `VERSION`, `PHP_VERSION`, `DB_IMAGE` based on `www/` |
| `p_project_install` | no | `clone` | Installs project dependencies |
| `p_after_import` | no | `db-import` | Configures the imported database and files for the box |

A service required by the platform is added with `add_service <service>` in `p_resolve` and `p_clone_detect`. Example: `_mage_services` in `platforms/magento/magento.sh`.

## Project from a repository

`clone` and `db-import` work without custom functions, because the core has defaults.

| Function | Core default |
|---|---|
| `p_clone_detect` | `VERSION` from `git describe`, PHP from `config.platform.php` or `require.php` in `composer.json`, `mariadb:11.4` |
| `p_project_install` | `composer install` when `composer.json` exists |
| `p_after_import` | Prints the database connection details |

| `p_after_import` task | Pattern in existing platforms |
|---|---|
| Table prefix | Shortest table name with the suffix of a known table, e.g. `%core_config_data`, `%configuration`, `%options` |
| Configuration file | `<file>.<timestamp>.orig` copy, then database credentials overwritten: host `db`, `DB_NAME`, `DB_USER`, `DB_PASS` |
| Shop address | `shop_url` (`https://`) or `shop_hostport` in the database. Platform HTTPS flags enabled |
| Mail | SMTP disabled, sending via `mail()`, which goes to Mailpit |
| Admin account | `ADMIN_USER` / `ADMIN_EMAIL` with `ADMIN_PASSWORD`. An existing account gets the new password |

## Helpers available in functions

| Name | Meaning |
|---|---|
| `php_run [-e K=V]` | Runs a script from stdin in the `php` container, in `/var/www/html`, with the host UID |
| `db_exec [options]` | `mariadb` client as root in the `db` container |
| `compose <args>` | `docker compose` for the box, e.g. `compose exec -T web nginx -s reload` |
| `versions_query <source> <list\|resolve>` | Version and PHP selection via `src/versions.py`. Sources: `prestashop`, `composer` (Magento, Symfony, Laravel, Shopware), `woocommerce`, `lock`, `project` |
| `shop_url`, `shop_hostport`, `shop_locale` | Box address, host with port, locale from `SHOP_LANG` |
| `add_service <service>[:tag]` | Adds a service from `docker/services/` to `SERVICES`. A tag replaces the tag of an added service |
| `service_default <service> <tag>` | Sets the tag of a service listed without one |
| `has_service <service>` | Returns 0 when the service is in `SERVICES`, with or without a tag |
| `log`, `ok`, `die` | Messages. `die` ends the command |
| `NAME`, `WWW_DIR`, `DB_NAME`, `DB_USER`, `DB_PASS`, `ADMIN_*`, `SHOP_*` | Box data. Available in the `php` container as `DB_*` and `ADMIN_*` environment variables |

A new version API requires a `rows_<source>` function in `src/versions.py`.

## `nginx.conf`

| Requirement | Reason |
|---|---|
| `listen 80 default_server;` | `phpbox-proxy` connects to `phpbox-<name>-web-1:80` |
| `root /var/www/html;` | `www/` is mounted at this path in `web` and `php` |
| `fastcgi_pass php:9000;` | PHP-FPM service in the box compose project |
| `fastcgi_param HTTPS $fastcgi_https if_not_empty;` with the `$fastcgi_https` map | TLS terminates in `phpbox-proxy`, PHP learns about HTTPS from the header |

Full file: see "Skeletons".

Box-specific configuration goes to `boxes/<name>/nginx/`. The compose overlay mounts this directory in `web`, and `nginx.conf` includes the file with a pattern that does not require it to exist.

```yaml
# platforms/<name>/<name>.yml, in platform.sh: P_COMPOSE=("$PLATFORM_DIR/<name>.yml")
services:
  web:
    volumes:
      - ${ENV_DIR}/nginx:/etc/nginx/phpbox:ro
```

```nginx
# [f] is a glob: a missing admin.conf is skipped instead of failing nginx
include /etc/nginx/phpbox/admin.con[f];
```

After changing the file in a running box: `compose exec -T web nginx -s reload`.

## Skeletons

Files for an `example` platform with a CLI installer and an `index.php` front controller.

### `platforms/example/platform.sh`

```bash
# shellcheck shell=bash disable=SC2034
P_TITLE="Example"
P_SHORT="ex"

p_resolve() {
  [[ "$1" == latest || "$1" == 1.* ]] || die "Version '$1' not found (phpbox versions example)"
  VERSION="1.0.0"
  PHP_VERSION="8.3"
  DB_IMAGE="mariadb:11.4"
  DOWNLOAD_URL="https://example.com/example-$VERSION.zip"
}

p_versions() { echo "1.0.0          PHP 8.3"; }

p_install() {
  php_run -e URL="$DOWNLOAD_URL" -e SHOP_URL="$(shop_url)" <<'SH'
set -euo pipefail
curl -fsSL "$URL" -o /tmp/example.zip
unzip -q /tmp/example.zip -d .
php bin/install --db-host=db --db-name="$DB_NAME" --db-user="$DB_USER" --db-password="$DB_PASS" --url="$SHOP_URL"
SH
}

p_snapshot_excludes() { echo "var/cache"; }

p_clear_cache() { rm -rf "$WWW_DIR"/var/cache/*; }

p_info() {
  cat <<INFO
  Shop:    $(shop_url)
  Admin:   $(shop_url)/admin   ($ADMIN_USER / $ADMIN_PASSWORD)
INFO
}
```

### `platforms/example/nginx.conf`

```nginx
map $http_x_forwarded_proto $fastcgi_https {
    https on;
    default "";
}

server {
    listen 80 default_server;
    root /var/www/html;
    index index.php;
    client_max_body_size 64M;

    location = /favicon.ico { access_log off; log_not_found off; }
    location ~ /\.(?!well-known) { deny all; }

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        try_files $uri =404;
        include fastcgi_params;
        fastcgi_param HTTPS $fastcgi_https if_not_empty;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_pass php:9000;
        fastcgi_buffers 16 32k;
        fastcgi_buffer_size 64k;
        fastcgi_read_timeout 300s;
    }
}
```

### `platforms/example/README.md`

````markdown
# Example

The `example` platform installs Example from `example.com`.

## Versions

| Example | PHP | MariaDB |
|---|---|---|
| 1.x | 8.3 | 11.4 |

## Project from a repository

```bash
phpbox clone example git@gitlab.example:client/shop.git
phpbox db-import shop ~/dumps/shop.sql.gz
```

| `db-import` change | Value |
|---|---|
| Shop address | `https://<name>.localhost` |
| Admin account | `ADMIN_USER` / `ADMIN_PASSWORD` |
````

A new platform is also added to the platform table in the main `README.md`.

## Verification

| Command | Expected result |
|---|---|
| `phpbox versions <platform>` | Version list |
| `phpbox create <platform> latest` | `✔ Done`, shop and admin open at the addresses from `p_info` |
| `phpbox reset <box>` | State after installation |
| `phpbox copy <box> <copy>` | Copy at the new address. Only with `p_rehost` |
| `phpbox clone <platform> <repo>` + `phpbox db-import <box> <dump>` | Shop at the box address, `ADMIN_*` login to the admin panel |
| `phpbox remove <box> -y` | Box removed |

`platforms/<name>/README.md` has sections in this order: Versions, Project from a repository. Platform-specific sections go at the end.
