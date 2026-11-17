# shellcheck shell=bash disable=SC2034

# Install a platform version into a new box: cmd_create <platform> <version> [options]
cmd_create() {
  local platform="${1:-}" version="${2:-}"; shift 2 || true
  [[ -n "$platform" && -n "$version" ]] || die "Usage: phpbox create <platform> <version|latest> [--name N] [--lang xx] [--php X.Y] [--<service>]"
  load_platform "$platform"
  parse_options "$@"
  log "Resolving $P_TITLE version '$version'…"
  p_resolve "$version"
  KIND=fresh
  init_env "${OPT_NAME:-$P_SHORT${VERSION//[^0-9]/}}"
  mkdir -p "$WWW_DIR"
  save_env

  log "Starting containers…"
  box_up
  log "Installing $P_TITLE $VERSION…"
  p_install || die "Installation failed. Logs: phpbox logs $NAME · remove: phpbox remove $NAME"
  take_snapshot
  ok "Done: $NAME"
  print_info
}

# Clone a project repository into a new box without a database: cmd_clone <platform> <git-repo> [options]
cmd_clone() {
  local platform="${1:-}" repo="${2:-}" base; shift 2 || true
  [[ -n "$platform" && -n "$repo" ]] || die "Usage: phpbox clone <platform> <git-repo> [--branch B] [--name N] [--php X.Y] [--<service>]"
  load_platform "$platform"
  parse_options "$@"
  base="${repo%.git}"; base="${base##*[/:]}"; base="${base,,}"; base="${base//[^a-z0-9-]/-}"
  KIND=project
  init_env "${OPT_NAME:-$base}"

  log "git clone $repo…"
  mkdir -p "$BOXES_DIR/$NAME"
  git clone ${OPT_BRANCH:+--branch "$OPT_BRANCH"} "$repo" "$WWW_DIR" || { rm -rf "${BOXES_DIR:?}/$NAME"; die "git clone failed"; }
  p_clone_detect
  composer_detect
  save_env
  write_ssh_override

  log "Starting containers…"
  box_up
  p_project_install || die "Dependency install failed. Fix and retry: phpbox shell $NAME → composer install"
  ok "Code ready: $NAME"
  echo "  Next step: phpbox db-import $NAME <dump.sql[.gz|.zst]>"
}

# Use an existing project directory as the code of a new box, without copying or cloning it: cmd_add <platform> <path> [options]
cmd_add() {
  local platform="${1:-}" path="${2:-}" dir base; shift 2 || true
  [[ -n "$platform" && -n "$path" ]] || die "Usage: phpbox add <platform> <path> [--name N] [--php X.Y] [--<service>]"
  dir=$(realpath -e "$path" 2>/dev/null) && [[ -d "$dir" ]] || die "Not a directory: $path"
  load_platform "$platform"
  parse_options "$@"
  base=$(basename "$dir"); base="${base,,}"; base="${base//[^a-z0-9-]/-}"
  KIND=project
  init_env "${OPT_NAME:-$base}" "$dir"
  grep -qsxF "CODE_DIR=$(printf '%q' "$dir")" "$BOXES_DIR"/*/.env && die "Directory $dir already belongs to another environment (phpbox list)"
  p_clone_detect
  composer_detect
  save_env
  write_ssh_override

  log "Starting containers…"
  box_up
  if [[ ! -d "$WWW_DIR/vendor" ]]; then
    p_project_install || die "Dependency install failed. Fix and retry: phpbox shell $NAME → composer install"
  fi
  run_hooks post-start
  ok "Code ready: $NAME ($WWW_DIR)"
  echo "  Next step: phpbox db-import $NAME <dump.sql[.gz|.zst]>"
}

# Import a dump into a box and configure it for local use; --strip (default DB_STRIP) imports the listed tables empty: cmd_db_import <name> <dump> [--strip "<tables|@group>..."]
cmd_db_import() {
  local dump="${2:-}" reader=cat strip patterns
  load_env "${1:-}"
  shift $(($# < 2 ? $# : 2))
  strip="$DB_STRIP"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strip) strip="${2:-}"; shift $(($# < 2 ? $# : 2)) ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -f "$dump" ]] || die "Usage: phpbox db-import <name> <dump.sql[.gz|.zst|.bz2]> [--strip \"<tables|@group>...\"]"
  patterns=$(strip_patterns "$strip")
  command -v pv >/dev/null && reader=pv
  box_up
  log "Import $(basename "$dump") ($(du -h "$dump" | cut -f1))${patterns:+, empty: $patterns}…"
  "$reader" "$dump" | dump_decompress "$dump" | dump_fix | dump_strip "$patterns" | db_load --max-allowed-packet=1G
  p_after_import || die "Post-import configuration failed"
  run_hooks post-import
  take_snapshot
  ok "Done: $NAME"
  print_info
}

# Copy a box with its current database under a new name and address: cmd_copy <source> <name>
cmd_copy() {
  local src="${1:-}" dst="${2:-}" src_db src_url src_www dump; shift 2 || true
  [[ -n "$src" && -n "$dst" ]] || die "Usage: phpbox copy <source> <name>"
  [[ $# -eq 0 ]] || die "Unknown option: $1"
  load_env "$src"
  declare -F p_rehost >/dev/null || die "Platform '$PLATFORM' does not support copy"
  ( init_env "$dst" )
  src_db="$DB_NAME" src_url=$(shop_url) src_www="$WWW_DIR" dump="$BOXES_DIR/$src/copy-$dst.sql.gz"

  box_up
  log "Dumping '$src' database…"
  db_dump > "$dump"

  init_env "$dst"
  DB_NAME="$src_db"
  log "Copying files…"
  mkdir -p "$BOXES_DIR/$NAME"
  # shellcheck disable=SC2046
  rsync -a $(snapshot_excludes) "$src_www/" "$WWW_DIR/"
  [[ -f "$BOXES_DIR/$src/compose.yml" ]] && cp "$BOXES_DIR/$src/compose.yml" "$BOXES_DIR/$NAME/compose.yml"
  save_env

  log "Starting containers…"
  box_up
  log "Importing database…"
  gunzip -c "$dump" | db_load
  rm -f "$dump"
  log "Switching URLs $src_url → $(shop_url)…"
  p_rehost "$src_url"
  take_snapshot
  ok "Copied '$src' → '$NAME'"
  print_info
}

# Make the current state the new reset point: cmd_snapshot <name>
cmd_snapshot() { load_env "${1:-}"; box_up; take_snapshot; }

# Restore the snapshot; cloned projects and --db-only restore the database only: cmd_reset <name> [--db-only]
cmd_reset() {
  local snap db_only=0
  load_env "${1:-}"
  [[ "${2:-}" == "--db-only" || "$KIND" == project ]] && db_only=1
  snap="$BOXES_DIR/$NAME/snapshot"
  [[ -f "$snap/db.sql.gz" ]] || die "No snapshot for '$NAME'"
  box_up
  log "Restoring database…"
  gunzip -c "$snap/db.sql.gz" | db_load
  if [[ $db_only -eq 0 ]]; then
    log "Restoring files…"
    # shellcheck disable=SC2046
    rsync -a --delete $(snapshot_excludes) "$snap/www/" "$WWW_DIR/"
  fi
  log "Clearing cache…"
  p_clear_cache
  ok "Reset '$NAME' to state from $(cat "$snap/created_at" 2>/dev/null || echo snapshot)"
}

# Start a box: cmd_start <name>
cmd_start() { load_env "${1:-}"; box_up; run_hooks post-start; print_info; }

# Add or remove a service of a box, apply it to the containers and let the platform reconfigure: cmd_service <add|remove> <name> <service[:tag]>
cmd_service() {
  local action="${1:-}" service="${3:-}"
  [[ ( "$action" == add || "$action" == remove ) && -n "$service" ]] || die "Usage: phpbox service <add|remove> <name> <service[:tag]> ($(services))"
  load_env "${2:-}"
  if [[ "$action" == add ]]; then
    add_service "$service"
  else
    service="${service%%:*}"
    has_service "$service" || die "Service '$service' is not used by '$NAME' ($SERVICES)"
    [[ "$service" != "$SEARCH" ]] || die "'$service' is the search engine of '$NAME' (SEARCH in .env)"
    remove_service "$service"
  fi
  save_env
  log "Applying services: ${SERVICES:-none}…"
  box_up --remove-orphans
  if declare -F p_service_changed >/dev/null; then
    p_service_changed "$action" "${service%%:*}" || die "Platform configuration for '$service' failed"
  fi
  run_hooks post-service-change -e PHPBOX_ACTION="$action" -e PHPBOX_SERVICE="${service%%:*}"
  ok "Services of '$NAME': ${SERVICES:-none}"
}

# Stop a box and remove its containers: cmd_stop <name>
cmd_stop() { load_env "${1:-}"; box_down; }

# Remove containers of all boxes and shared containers; running boxes are saved to boxes/.up.
cmd_down() {
  local f n running=()
  for f in "$BOXES_DIR"/*/.env; do
    [[ -f "$f" ]] || continue
    n=$(basename "$(dirname "$f")")
    box_exists "$n" || continue
    box_running "$n" && running+=("$n")
    log "Stopping '$n'…"
    ( load_env "$n"; box_down )
  done
  if [[ ${#running[@]} -gt 0 ]]; then printf '%s\n' "${running[@]}" > "$UP_FILE"; fi
  shared down --remove-orphans 2>/dev/null
  ok "phpbox stopped; ports $HTTP_PORT, $HTTPS_PORT, $MAILPIT_PORT, $PHPMYADMIN_PORT are free"
}

# Start the shared containers and the boxes saved by cmd_down.
cmd_up() {
  local n
  ensure_tools
  shared_up
  if [[ -f "$UP_FILE" ]]; then
    while read -r n; do
      [[ -f "$BOXES_DIR/$n/.env" ]] || continue
      log "Starting '$n'…"
      ( load_env "$n"; box_up >/dev/null; run_hooks post-start ) </dev/null
    done < "$UP_FILE"
    rm -f "$UP_FILE"
  fi
  cmd_list
}

# Remove a box with its database, files and certificate: cmd_remove <name> [-y]
cmd_remove() {
  local answer
  load_env "${1:-}"
  if [[ "${2:-}" != "-y" ]]; then
    if [[ -n "$CODE_DIR" ]]; then echo "The code directory stays: $CODE_DIR"
    elif [[ "$KIND" == project ]]; then echo "WARNING: the code directory is a git repository; unpushed changes will be lost ($WWW_DIR)"; fi
    read -r -p "Remove environment '$NAME' with its database and files? [y/N] " answer
    [[ "$answer" =~ ^[yY]$ ]] || exit 0
  fi
  shared_network disconnect
  compose down -v --remove-orphans
  rm -rf "${BOXES_DIR:?}/$NAME"
  rm -f "$CACHE_DIR/certs/$NAME.pem" "$CACHE_DIR/certs/$NAME-key.pem"
  ok "Removed '$NAME'"
}

# Print the compose projects with a running container, space-separated and padded with spaces.
running_projects() { echo " $(docker ps --filter label=com.docker.compose.project --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | sort -u | paste -sd' ') "; }

# Print all boxes with platform, version, address and status; --size adds the disk size of boxes/<name>, --json prints a JSON array: cmd_list [--size] [--json]
# shellcheck disable=SC2120
cmd_list() {
  local f running size="" sizes=() n sep=""
  running=$(running_projects)
  if [[ "${1:-}" == --json ]]; then
    echo "["
    for f in "$BOXES_DIR"/*/.env; do
      [[ -f "$f" ]] || continue
      n=$(basename "$(dirname "$f")")
      printf '%s' "$sep"; sep=","
      ( load_env "$n" >/dev/null; box_json "$running" )
    done
    echo "]"
    return 0
  fi
  if [[ "${1:-}" == --size ]]; then
    mapfile -t sizes < <(du -sh "$BOXES_DIR"/*/ 2>/dev/null)
    size=SIZE
  fi
  printf '%-16s %-12s %-12s %-36s %-8s %s\n' NAME PLATFORM VERSION URL STATUS "$size"
  for f in "$BOXES_DIR"/*/.env; do
    [[ -f "$f" ]] || continue
    (
      SHOP_HOST=localhost
      # shellcheck source=/dev/null
      source "$f"
      status=stopped
      [[ "$running" == *" phpbox-$NAME "* ]] && status=running
      size=""
      for s in "${sizes[@]}"; do [[ "${s#*$'\t'}" == "$BOXES_DIR/$NAME/" ]] && size="${s%%$'\t'*}"; done
      printf '%-16s %-12s %-12s %-36s %-8s %s\n' "$NAME" "$PLATFORM" "$VERSION" "$(shop_url)" "$status" "$size"
    )
  done
}

# Print the addresses and credentials of a box; --json prints them with the containers as one JSON object: cmd_info <name> [--json]
cmd_info() {
  load_env "${1:-}"
  if [[ "${2:-}" == --json ]]; then
    box_json "$(running_projects)" "$(compose ps -a --format json 2>/dev/null)"
    return 0
  fi
  print_info; print_stack
}

# Print the features of this phpbox for scripts and plugins as a JSON object.
cmd_capabilities() {
  python3 -I -c 'import json, sys; print(json.dumps({"capabilities": sys.argv[1:]}))' \
    add db-import-strip hooks info-json list-json nginx-includes project-config service
}

# Print the loaded box as JSON; the second argument is the output of compose ps --format json: box_json <running-projects> [containers-json]
box_json() {
  local status=stopped
  [[ "$1" == *" phpbox-$NAME "* ]] && status=running
  J_NAME="$NAME" J_PLATFORM="$PLATFORM" J_TITLE="$P_TITLE" J_VERSION="$VERSION" J_KIND="$KIND" J_PHP="$PHP_VERSION" \
  J_DB_IMAGE="$DB_IMAGE" J_URL="$(shop_url)" J_STATUS="$status" J_CODE_DIR="$WWW_DIR" J_EXTERNAL="${CODE_DIR:+1}" \
  J_BOX_DIR="$BOXES_DIR/$NAME" J_SERVICES="$SERVICES" J_DB_PORT="$DB_PORT" J_DB_NAME="$DB_NAME" J_DB_USER="$DB_USER" \
  J_DB_PASS="$DB_PASS" J_DB_ROOT_PASS="$DB_ROOT_PASS" J_ADMIN_PATH="${P_ADMIN_PATH:-}" J_ADMIN_USER="$ADMIN_USER" \
  J_ADMIN_PASSWORD="$ADMIN_PASSWORD" J_CONTAINERS="${2-}" J_WITH_CONTAINERS="${2+1}" \
    python3 -I -c 'import json, os
e = os.environ
box = {
    "name": e["J_NAME"], "platform": e["J_PLATFORM"], "title": e["J_TITLE"], "version": e["J_VERSION"],
    "kind": e["J_KIND"], "php": e["J_PHP"], "status": e["J_STATUS"], "url": e["J_URL"],
    "admin": {"url": e["J_URL"] + "/" + e["J_ADMIN_PATH"], "user": e["J_ADMIN_USER"], "password": e["J_ADMIN_PASSWORD"]}
             if e["J_ADMIN_PATH"] else None,
    "code_dir": e["J_CODE_DIR"], "external_code": bool(e["J_EXTERNAL"]), "box_dir": e["J_BOX_DIR"],
    "services": [{"name": s.split(":", 1)[0], "tag": s.split(":", 1)[1] if ":" in s else None} for s in e["J_SERVICES"].split()],
    "database": {"host": "127.0.0.1", "port": int(e["J_DB_PORT"]), "name": e["J_DB_NAME"], "user": e["J_DB_USER"],
                 "password": e["J_DB_PASS"], "root_password": e["J_DB_ROOT_PASS"], "image": e["J_DB_IMAGE"]},
}
hosts = os.path.join(e["J_BOX_DIR"], "nginx", "hosts")
if os.path.isfile(hosts):
    box["stores"] = [dict(zip(("type", "code", "url"), line.split())) for line in open(hosts) if line.strip()]
if e["J_WITH_CONTAINERS"]:
    raw = e["J_CONTAINERS"].strip()
    rows = json.loads(raw) if raw.startswith("[") else [json.loads(l) for l in raw.splitlines() if l.strip()]
    box["containers"] = [{"service": r.get("Service"), "name": r.get("Name"), "image": r.get("Image"), "state": r.get("State")} for r in rows]
print(json.dumps(box, indent=None))'
}

# Print the versions a platform can install: cmd_versions <platform>
cmd_versions() { [[ -n "${1:-}" ]] || die "Usage: phpbox versions <platform> ($(platforms))"; load_platform "$1"; p_versions; }

# Open a shell in the php or the given service container: cmd_shell <name> [service]
cmd_shell() { load_env "${1:-}"; compose exec "${2:-php}" sh -c 'command -v bash >/dev/null && exec bash || exec sh'; }

# Run a command in the php or the given service container without a TTY: cmd_exec <name> [--service S] <command...>
cmd_exec() {
  local service=php
  load_env "${1:-}"; shift
  [[ "${1:-}" == --service ]] && { service="${2:-}"; shift $(($# < 2 ? $# : 2)); }
  [[ -n "$service" && $# -gt 0 ]] || die "Usage: phpbox exec <name> [--service S] <command...>"
  compose exec -T "$service" "$@"
}

# Open the MariaDB console of a box: cmd_db <name>
cmd_db() { load_env "${1:-}"; compose exec db mariadb -uroot -p"$DB_ROOT_PASS" "$DB_NAME"; }

# Follow the container logs of a box: cmd_logs <name>
cmd_logs() { load_env "${1:-}"; compose logs -f --tail=100; }

# Print the platform addresses followed by database, phpMyAdmin, Mailpit and files.
print_info() {
  p_info
  echo "  DB:      127.0.0.1:$DB_PORT  $DB_NAME / $DB_USER / $DB_PASS  (root: $DB_ROOT_PASS)"
  echo "  DB UI:   $(SHOP_HOST=phpmyadmin.localhost shop_url)/?server=$(pma_server)"
  echo "  Mail:    $(SHOP_HOST=mailpit.localhost shop_url)"
  echo "  Files:   $WWW_DIR"
}

# Print the platform, PHP version, disk size of boxes/<name>, volumes and every container of the box with its image and state.
print_stack() {
  local service image state
  echo
  echo "  Platform: $P_TITLE $VERSION ($KIND)"
  echo "  PHP:      $PHP_VERSION"
  echo "  Size:     $(du -sh "$BOXES_DIR/$NAME" 2>/dev/null | cut -f1)"
  print_volumes
  echo "  Containers:"
  while read -r service image; do
    state=$(compose ps -a --format '{{.State}}' "$service" 2>/dev/null)
    printf '    %-12s %-45s %s\n' "$service" "$image" "${state:-not created}"
  done < <(compose config --format json | python3 -I -c 'import json, sys
for name, s in sorted(json.load(sys.stdin)["services"].items()):
    print(name, s.get("image", "-"))')
}

# Print the docker volumes of the box with their disk size, measured in one alpine/socat container.
print_volumes() {
  local volumes v mounts=() paths=() size path
  mapfile -t volumes < <(docker volume ls -q --filter "label=com.docker.compose.project=phpbox-$NAME")
  (( ${#volumes[@]} )) || return 0
  for v in "${volumes[@]}"; do mounts+=(-v "$v:/v/$v:ro"); paths+=("/v/$v"); done
  echo "  Volumes:"
  docker run --rm --entrypoint du "${mounts[@]}" alpine/socat:1.8.0.3 -sh "${paths[@]}" 2>/dev/null \
    | while read -r size path; do printf '    %-45s %s\n' "${path#/v/}" "$size"; done
}

# Print the phpMyAdmin server number of the loaded box; docker/phpmyadmin.php numbers boxes in glob order.
pma_server() {
  local LC_ALL=C i=0 f
  for f in "$BOXES_DIR"/*/.env; do
    i=$((i + 1))
    [[ "$f" == "$BOXES_DIR/$NAME/.env" ]] && { echo "$i"; return; }
  done
}
