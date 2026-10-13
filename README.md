# phpbox

Local PHP shops and apps on Docker, with snapshots. `create` installs the chosen platform version, `reset` restores it to a snapshot.

| Platform | Versions | Details |
|---|---|---|
| `prestashop` | 8.x, 9.x | [platforms/prestashop](platforms/prestashop/README.md) |
| `laravel` | all on Packagist, PHP 8.0+ | [platforms/laravel](platforms/laravel/README.md) |
| `magento` | 2.4.4+ | [platforms/magento](platforms/magento/README.md) |
| `mageos` | 1.0+ (Magento 2.4.6+) | [platforms/mageos](platforms/mageos/README.md) |
| `shopware` | 6.6+ | [platforms/shopware](platforms/shopware/README.md) |
| `symfony` | all on Packagist, PHP 8.0+ | [platforms/symfony](platforms/symfony/README.md) |
| `woocommerce` | all with PHP 8.0+ | [platforms/woocommerce](platforms/woocommerce/README.md) |

Versions, installation, reset, copy and import of each platform are described in its directory. Adding a platform: [docs/adding-a-platform.md](docs/adding-a-platform.md).

## Requirements

- Linux (x86_64 or arm64)
- Docker with the `docker compose` plugin (v2)
- `bash`, `curl`, `rsync`, `python3`
- `mmilewski/php-fpm:8.0+` images on Docker Hub or locally
- `vm.max_map_count >= 262144` for OpenSearch

## Installation

```bash
git clone <repo> ~/phpbox
ln -s ~/phpbox/phpbox ~/.local/bin/phpbox
cp ~/phpbox/phpbox.conf.example ~/phpbox/phpbox.conf
```

The symlink in `~/.local/bin` runs `phpbox` from any directory. The script resolves it with `readlink -f`, so `boxes/`, `cache/` and `phpbox.conf` stay in the repository directory.

## Quick start

```bash
phpbox create prestashop 8.2.1                 # exact version
phpbox create prestashop 9                     # latest stable 9.x
phpbox create mageos latest
phpbox create magento 2.4.8-p3 --name client
phpbox create woocommerce 10 --wp 6.8.3 --lang en
```

Addresses and credentials: `phpbox info <name>`.

## Commands

| Command | Description |
|---|---|
| `create <platform> <version> [options]` | Installation. Version: full, prefix (`8.2`, `9`) or `latest` |
| `clone <platform> <git-repo> [options]` | Project from a repository: `git clone` + `composer install`, no database |
| `copy <source> <name>` | Copy of an environment with its current database, new host and database port |
| `db-import <name> <dump>` | Database import and configuration for the local environment, then snapshot |
| `reset <name> [--db-only]` | Restores the database (and files) to the snapshot. Project from `clone`: database only |
| `snapshot <name>` | The current state becomes the new reset point |
| `start` / `stop <name>` | Start / stop |
| `up` / `down` | Start / stop the whole phpbox. `down` frees the ports and remembers running environments, `up` resumes them |
| `list [--size]` | Environments and their status. `--size` adds the disk usage of `boxes/<name>` (`du`, about 0.5 s per box) |
| `info <name>` | Addresses, credentials, platform, PHP version, disk size of `boxes/<name>`, volumes with size and containers with image and state |
| `shell <name> [service]` | Bash in the PHP container (your UID, `composer`, `wp` in PATH) or in the given service, e.g. `node` |
| `db <name>` | MariaDB console |
| `logs <name>` | Container logs |
| `remove <name> [-y]` | Removes the environment with its database and files |
| `versions <platform>` | Available versions with their PHP range |

| `create` option | Description |
|---|---|
| `--name N` | Environment name, defaults to the platform prefix + version digits. `phpmyadmin` and `mailpit` are reserved |
| `--lang xx` | Shop language (`pl` → `pl_PL`) |
| `--php X.Y` | PHP image version, defaults to the highest supported by the platform |
| `--<service>[:tag]` | Service from `docker/services/`, e.g. `--redis` or `--redis:7.4-alpine`. Also available in `clone` |

Platform-specific options, e.g. `--wp` for WooCommerce, are in the platform README.

## Services

A service is a `docker/services/<name>.yml` file. A box runs the services listed in `SERVICES` in its `.env`, each in a separate container of that box.

An entry `<name>:<tag>` sets the image tag. `compose()` passes it as `<NAME>_TAG`, e.g. `REDIS_TAG`. An entry without a tag uses the platform default, then the default in the service file.

```bash
SERVICES='opensearch:2.19.1 redis:7.4-alpine node:14-alpine'
```

| Service | Image | Host in the box network | Notes |
|---|---|---|---|
| `redis` | `redis:${REDIS_TAG:-7.2-alpine}` | `redis` | No disk persistence |
| `valkey` | `valkey/valkey:${VALKEY_TAG:-8.1-alpine}` | `valkey` | Redis replacement |
| `rabbitmq` | `rabbitmq:${RABBITMQ_TAG:-3.13-management-alpine}` | `rabbitmq` | Panel at the address from `phpbox info` (`guest` / `guest`). Requires a `-management` tag |
| `opensearch` | `opensearchproject/opensearch:${OPENSEARCH_TAG:-2.19.1}` | `search` | Disk watermarks disabled |
| `elasticsearch` | `elasticsearch:${ELASTICSEARCH_TAG:-7.17.25}` | `search` | Disk watermarks disabled |
| `memcached` | `memcached:${MEMCACHED_TAG:-1.6-alpine}` | `memcached` | 256 MB |
| `cron` | image and volumes of the `php` service (`extends`) | — | Runs the platform `P_CRON` every 60 s |
| `node` | `node:${NODE_TAG:-22-alpine}` | — | Tool container with `www/` and the host UID. Entry: `phpbox shell <name> node` |

| Situation | Action |
|---|---|
| `--<service>[:tag]` flag on `create` or `clone` | The service is added to `SERVICES`. A later tag of the same service replaces the earlier one |
| Service added later | Append it to `SERVICES` in `.env` and run `phpbox start <name>`. Platform configuration (e.g. Magento `env.php`) is not updated |
| `SEARCH` in `.env` | `load_env` adds its value to the services |
| Tag changed later | Edit the tag in `SERVICES` and run `phpbox start <name>`. A downgrade does not start on the existing volume |
| New service | A `docker/services/<name>.yml` file with `image: <image>:${<NAME>_TAG:-<default>}`. The `--<name>` flag works immediately |

`compose()` in `src/docker.sh` merges the files in this order: `docker/compose.yml`, platform `P_COMPOSE`, one file per entry in `SERVICES`, `boxes/<name>/compose.yml`.

Without disabled disk watermarks, OpenSearch 2.x sets a persistent `cluster.blocks.create_index` block above 95% disk usage and reindexing fails with 403. The search index is not part of the snapshot.

## Architecture

```
phpbox                   # default configuration, loads src/*.sh, dispatches the command
src/core.sh              # messages, options, platform and .env loading, ports, shop address
src/docker.sh            # box compose, shared containers, box_up / box_down, tools
src/tls.sh               # mkcert, CA, box certificates
src/database.sh          # queries, dump, import, snapshot
src/commands.sh          # cmd_* in workflow order: create, clone, db-import, copy, reset…
src/composer_auth.py     # COMPOSER_AUTH from the host auth.json and keys from phpbox.conf
src/versions.py          # version and PHP selection from platform APIs
docker/shared.yml        # compose project "phpbox": proxy, Mailpit, phpMyAdmin, phpbox network
docker/compose.yml       # web (nginx) + php (mmilewski/php-fpm) + loopback (socat) + db (MariaDB)
docker/php.ini           # memory 2G, sendmail → Mailpit, date.timezone = SHOP_TZ
docker/proxy.conf        # phpbox-proxy: <name>.localhost → box web, phpmyadmin/mailpit.localhost
docker/phpmyadmin.php    # phpMyAdmin server list from boxes/*/.env
docker/services/<service>.yml  # see "Services"
platforms/<p>/           # platform.sh, nginx.conf, README.md
docs/                    # how phpbox works, adding a platform
tests/                   # tests: tests/run.sh
cache/                   # packages, composer and wp-cli cache, bin/{composer,wp,mailpit}, certs/
boxes/<name>/{.env,www/,snapshot/,nginx/}
boxes/.up                # boxes running before phpbox down
```

| Container | Role |
|---|---|
| `web` | `nginx:stable-alpine`, configuration from `platforms/<p>/nginx.conf`, no host port |
| `php` | `mmilewski/php-fpm:<PHP_VERSION>`, runs with the host UID/GID |
| `loopback` | `alpine/socat` in the `php` network namespace. `127.0.0.1:HTTP_PORT` → `web:80`, `127.0.0.1:HTTPS_PORT` → `phpbox-proxy:443`, so the shop address works from the `php` container (WordPress cron, Action Scheduler, Magento self-calls) |
| `db` | MariaDB, version matched to the platform. Database named after the box (`-` → `_`), user `shop` / `shop`. `copy` keeps the source database name |
| services from `SERVICES` | Separate per environment, see "Services" |
| `phpbox-proxy` | `nginx:stable-alpine` on `HTTP_PORT` and `HTTPS_PORT`, `<name>.localhost` and `*.<name>.localhost` → `phpbox-<name>-web-1`. Terminates TLS, the box receives HTTP with `X-Forwarded-Proto` |
| `phpbox-mailpit` | One container for all environments. Receives mail from `mail()` (`mailpit sendmail` in `sendmail_path`). UI: `https://mailpit.localhost` or `MAILPIT_PORT` |
| `phpbox-phpmyadmin` | `phpmyadmin:5.2`, one container for all environments, attached to the `phpbox-<name>_default` network together with `phpbox-proxy`. UI: `https://phpmyadmin.localhost` or `PHPMYADMIN_PORT` |

`phpbox-proxy`, `phpbox-mailpit` and `phpbox-phpmyadmin` form the `phpbox` compose project from `docker/shared.yml`. Code walkthrough: [docs/how-phpbox-works.md](docs/how-phpbox-works.md).

PHP images cover versions 8.0–8.5.

## Reset

| Step | Mechanism |
|---|---|
| Database snapshot | `mariadb-dump` → `snapshot/db.sql.gz` |
| File snapshot | `rsync --delete` → `snapshot/www/`, without paths from `p_snapshot_excludes` |
| Database reset | `DROP DATABASE` + dump import |
| File reset | `rsync --delete` from the snapshot |
| Cleanup | Platform `p_clear_cache` |

A full `reset` overwrites code edited in `boxes/<name>/www`. Use `reset --db-only` in that case.

```bash
phpbox create prestashop 8.2 --name module-test
phpbox snapshot module-test     # after configuring the admin panel
phpbox reset module-test        # back to the snapshot state
```

## Environment copy

`copy` creates an independent environment from the current state of another one. It allows several agents or people to work on one shop in parallel.

```bash
phpbox copy m249 m249-a
```

| Step | Mechanism |
|---|---|
| Database | `mariadb-dump` of the source → import into the new container |
| Files | `rsync` of `www/` without paths from `p_snapshot_excludes` |
| Addresses | Platform `p_rehost <old-url>` |
| Snapshot | New, with the state after the copy |

## Configuration

| `phpbox.conf` variable | Default |
|---|---|
| `HTTP_PORT` | `80` |
| `HTTPS_PORT` | `443` |
| `BASE_PORT` | `8080`, first port slot |
| `MAILPIT_PORT` | `18025`, also `https://mailpit.localhost` |
| `PHPMYADMIN_PORT` | `18026`, also `https://phpmyadmin.localhost` |
| `SHOP_LANG`, `SHOP_COUNTRY`, `SHOP_CURRENCY`, `SHOP_TZ` | `pl`, `pl`, `PLN`, `Europe/Warsaw` |
| `ADMIN_USER`, `ADMIN_EMAIL`, `ADMIN_PASSWORD` | `admin`, `admin@example.com`, `admin123` |
| `MAGENTO_PUBLIC_KEY`, `MAGENTO_PRIVATE_KEY` | empty, required for `magento` |
| `GITHUB_TOKEN` | empty, required for private `https://github.com` repositories in `composer.json` |

Values are written to `boxes/<name>/.env` on `create`. Changing `phpbox.conf` later does not affect existing environments.

| Box `.env` variable | Change after `create` |
|---|---|
| `PHP_VERSION`, `SERVICES`, `PORT`, `DB_PORT` | Applied by `phpbox start <name>` |
| `DB_IMAGE` | Upgrade only. A MariaDB downgrade does not start on the existing volume |
| `NAME`, `DB_NAME`, `SHOP_HOST` | Do not change. They define the box directory, compose project, volume, certificate and `base_url` |
| `ADMIN_*`, `SHOP_LANG`, `SHOP_*` | No effect. Used only by `create` and `db-import` |

## Project from a repository

`clone` and `db-import` work for every platform. Database and file changes after import are described in the platform README.

```bash
phpbox clone <platform> git@gitlab.example:client/project.git --branch develop
phpbox db-import project ~/dumps/project.sql.gz
```

| `clone` option | Description |
|---|---|
| `--branch B` | Branch to clone |
| `--name N` | Environment name, defaults to the repository name |
| `--php X.Y` | Forces the PHP version |
| `--<service>[:tag]` | Service from `docker/services/` |

| Import step | Change |
|---|---|
| Dump | `utf8mb4_0900_*` collations → `utf8mb4_unicode_ci`, removed `DEFINER`, `/*!80xxx */` comments and `GTID_PURGED` |
| Configuration | Platform `p_after_import` |
| Snapshot | Database only. `reset` does not touch files, so code and git history stay |

### Private package access

| Mechanism | Source |
|---|---|
| SSH keys | `~/.ssh` mounted read-only at the same path |
| SSH agent | `$SSH_AUTH_SOCK` at the time of `clone`, stored in `boxes/<name>/compose.yml` |
| `auth.json` | From the repository and `~/.composer/auth.json` or `~/.config/composer/auth.json` |
| `phpbox.conf` | `MAGENTO_*` → `http-basic.repo.magento.com`, `GITHUB_TOKEN` → `github-oauth.github.com`, override entries from the host `auth.json` |

## HTTPS

Every box runs on `https://`. Certificates are issued by a local CA from [mkcert](https://github.com/FiloSottile/mkcert).

| Element | Mechanism |
|---|---|
| mkcert | From `PATH` or downloaded to `cache/bin/mkcert` |
| CA | The first run calls `mkcert -install` and asks for the `sudo` password. The CA lives in `mkcert -CAROOT` |
| Chrome and Firefox | Require `certutil`: `sudo apt install libnss3-tools`, then `mkcert -install` |
| Box certificate | `cache/certs/<name>.pem` for `<name>.localhost` and `*.<name>.localhost`. Browsers reject a `*.localhost` wildcard |
| Shared UI certificates | `cache/certs/phpmyadmin.pem` and `mailpit.pem`, hosts from `SHARED_HOSTS` in `phpbox` |
| Certificate selection | `phpbox-proxy` by SNI: `map $ssl_server_name` → `/certs/<name>.pem` |
| PHP sees HTTPS | `fastcgi_param HTTPS on` when `X-Forwarded-Proto` is `https` |
| Trust in the `php` container | `cache/certs/ca-bundle.pem`: host system CAs + mkcert CA. Set in `SSL_CERT_FILE`, `openssl.cafile`, `curl.cainfo` |

| Situation | Action |
|---|---|
| Box created before HTTPS | Database addresses stay `http://`. Switch: `phpbox copy <box> <new>` |
| `phpbox-proxy` with a different port configuration | `docker compose` in `shared_up` recreates the container |

`cache/` can be deleted after `phpbox down`. Tools and certificates are recreated on `phpbox up`, the CA stays in `mkcert -CAROOT`.

## Tests

```bash
tests/run.sh                         # unit: functions, versions, platforms, syntax, shellcheck (a few seconds)
tests/run.sh smoke                   # full Docker run for WooCommerce
tests/run.sh smoke prestashop 8.2.8  # full run for the chosen platform and version
```

| Test | Scope |
|---|---|
| `unit` | `parse_options`, addresses, ports, `.env`, `dump_fix`, `src/versions.py`, `src/composer_auth.py`, platform contract, `bash -n`, shellcheck |
| `smoke` | `create` → HTTPS → loopback → Mailpit → `reset` → `copy` → `stop`/`start` → `down`/`up` → `remove`. For WooCommerce also `clone` + `db-import` |

`smoke` runs in a temporary directory on ports 18080/18443 and requires a stopped phpbox (`phpbox down`). Your boxes and `phpbox.conf` stay untouched, and no containers or volumes remain after the test.

| Variable | Meaning |
|---|---|
| `PHPBOX_CONF` | Configuration file instead of `phpbox.conf` |
| `PHPBOX_BOXES_DIR` | Boxes directory instead of `boxes/` |

## Multiple environments

Every shop has the address `https://<name>.localhost`. With `HTTPS_PORT` other than 443 the address includes that port.

| Layer | Isolation |
|---|---|
| Docker | Separate compose project: containers, network, volumes, database port |
| Browser | Separate host, so separate cookies |
| DNS | `*.localhost` → loopback in Chrome, Firefox, curl and `systemd-resolved`, no `/etc/hosts` |

`phpbox-proxy` listens on `127.0.0.1` and `[::1]` because the system resolves `*.localhost` to `::1`.
