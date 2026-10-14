# How phpbox works

`phpbox` sets the default configuration, reads `phpbox.conf`, loads `src/*.sh` and runs the `cmd_<command>` function from `src/commands.sh`.

## Files

| File | Contents |
|---|---|
| `phpbox` | Defaults, `SHARED_HOSTS`, `phpbox.conf`, `usage`, command dispatch |
| `src/core.sh` | `log`/`ok`/`die`, `parse_options`, `load_platform`, `load_env`, `init_env`, `save_env`, ports, `shop_url`, default `p_clone_detect`/`p_project_install`/`p_after_import` |
| `src/docker.sh` | `compose`, `php_run`, `shared`, `box_up`, `box_down`, `download`, `ensure_tools` |
| `src/tls.sh` | `ensure_ca`, `ensure_cert`, `issue_cert` |
| `src/database.sh` | `db_exec`, `db_load`, `db_dump`, `dump_fix`, `take_snapshot` |
| `src/commands.sh` | `cmd_*` in workflow order, `print_info` |
| `platforms/<p>/platform.sh` | Platform `p_*` functions, described in [adding-a-platform.md](adding-a-platform.md) |

## Names

| Prefix | Meaning |
|---|---|
| `cmd_` | Command-line command: `phpbox create` → `cmd_create` |
| `p_` | Platform function from `platform.sh` |
| `box_` | Operation on the loaded box |
| `shared` | Shared containers: proxy, Mailpit, phpMyAdmin |
| `ensure_` | Prepare if missing. A second call does nothing |

## Box state

`load_env <name>` reads `boxes/<name>/.env` into global variables and then loads the platform. Every following function works on that box.

| Variable | Source |
|---|---|
| `NAME`, `PORT`, `DB_PORT`, `DB_NAME`, `SHOP_HOST` | `init_env` on creation, then `.env` |
| `VERSION`, `PHP_VERSION`, `DB_IMAGE` | `p_resolve` on `create`, `p_clone_detect` on `clone` |
| `KIND` | `fresh` for `create`, `project` for `clone` |
| `SERVICES` | `--<service>[:tag]` flags and services added by the platform in `p_resolve`/`p_clone_detect`, e.g. the Magento search engine. Entries are `<name>` or `<name>:<tag>` |
| `WWW_DIR`, `ENV_FILE` | `boxes/<name>/www`, `boxes/<name>/.env` |

`save_env` writes the variables listed in `ENV_KEYS` and the platform `P_ENV_KEYS`. There is no template `.env` file.

## Commands step by step

| Command | Functions in order |
|---|---|
| `create` | `load_platform` → `parse_options` → `p_resolve` → `init_env` → `save_env` → `box_up` → `p_install` → `take_snapshot` → `print_info` |
| `clone` | `load_platform` → `parse_options` → `init_env` → `git clone` → `p_clone_detect` → `save_env` → `write_ssh_override` → `box_up` → `p_project_install` |
| `db-import` | `load_env` → `box_up` → `dump_decompress` + `dump_fix` + `db_load` → `p_after_import` → `take_snapshot` |
| `copy` | `load_env` of the source → `box_up` → `db_dump` → `init_env` of the target → `rsync www/` → `save_env` → `box_up` → `db_load` → `p_rehost` → `take_snapshot` |
| `reset` | `load_env` → `box_up` → `db_load` from the snapshot → `rsync` of files, except `project` → `p_clear_cache` |
| `start` / `stop` | `load_env` → `box_up` / `box_down` |
| `up` | `ensure_tools` → `shared_up` → `box_up` of every box from `boxes/.up` |
| `down` | `box_down` of every box with containers → running ones saved to `boxes/.up` → `shared down` |
| `remove` | `load_env` → `compose down -v` → removal of `boxes/<name>` and the certificate |

## `box_up`

| Step | Function | Effect |
|---|---|---|
| 1 | `ensure_tools` | `cache/bin/{composer,wp,mailpit}`, mkcert, CA, `cache/certs/ca-bundle.pem`, certificates for `SHARED_HOSTS` |
| 2 | `ensure_cert` | `cache/certs/<name>.pem` |
| 3 | `shared_up` | `docker compose -p phpbox -f docker/shared.yml up -d` |
| 4 | `compose up -d --wait` | Box containers from the files listed in "Box compose files" |
| 5 | `shared_network connect` | Proxy and phpMyAdmin in the `phpbox-<name>_default` network |

`shared_network` connects the shared containers to the box network. Boxes do not attach `web` or `db` to the shared `phpbox` network, because the `db` and `php` service names of different boxes would collide in Docker DNS.

## Box compose files

`compose()` in `src/docker.sh` builds the `-f` list on every call. Later files override or extend earlier ones.

| Order | File | Source |
|---|---|---|
| 1 | `docker/compose.yml` | Always: `web`, `php`, `db`, `loopback` |
| 2 | Platform overlays | `P_COMPOSE` |
| 3 | `docker/services/<service>.yml` | One per entry in `SERVICES`, tag removed |
| 4 | `boxes/<name>/compose.yml` | When present: box-specific overrides, e.g. the SSH agent |

The project name is `phpbox-<name>` and `--env-file` is `boxes/<name>/.env`. Tags from `SERVICES` reach compose as `<NAME>_TAG` variables from `service_tags`.
