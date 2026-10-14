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
  save_env
  write_ssh_override

  log "Starting containers…"
  box_up
  p_project_install || die "Dependency install failed. Fix and retry: phpbox shell $NAME → composer install"
  ok "Code ready: $NAME"
  echo "  Next step: phpbox db-import $NAME <dump.sql[.gz|.zst]>"
}

# Import a dump into a box and configure it for local use: cmd_db_import <name> <dump>
cmd_db_import() {
  local dump="${2:-}" reader=cat
  load_env "${1:-}"
  [[ -f "$dump" ]] || die "Usage: phpbox db-import <name> <dump.sql[.gz|.zst|.bz2]>"
  command -v pv >/dev/null && reader=pv
  box_up
  log "Import $(basename "$dump") ($(du -h "$dump" | cut -f1))…"
  "$reader" "$dump" | dump_decompress "$dump" | dump_fix | db_load --max-allowed-packet=1G
  p_after_import || die "Post-import configuration failed"
  take_snapshot
  ok "Done: $NAME"
  print_info
}

# Copy a box with its current database under a new name and address: cmd_copy <source> <name>
cmd_copy() {
  local src="${1:-}" dst="${2:-}" src_db src_url dump; shift 2 || true
  [[ -n "$src" && -n "$dst" ]] || die "Usage: phpbox copy <source> <name>"
  [[ $# -eq 0 ]] || die "Unknown option: $1"
  load_env "$src"
  declare -F p_rehost >/dev/null || die "Platform '$PLATFORM' does not support copy"
  ( init_env "$dst" )
  src_db="$DB_NAME" src_url=$(shop_url) dump="$BOXES_DIR/$src/copy-$dst.sql.gz"

  box_up
  log "Dumping '$src' database…"
  db_dump > "$dump"

  init_env "$dst"
  DB_NAME="$src_db"
  log "Copying files…"
  mkdir -p "$BOXES_DIR/$NAME"
  # shellcheck disable=SC2046
  rsync -a $(snapshot_excludes) "$BOXES_DIR/$src/www/" "$WWW_DIR/"
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
cmd_start() { load_env "${1:-}"; box_up; print_info; }

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
      ( load_env "$n"; box_up >/dev/null ) </dev/null
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
    [[ "$KIND" == project ]] && echo "WARNING: www/ is a git repository; unpushed changes will be lost ($WWW_DIR)"
    read -r -p "Remove environment '$NAME' with its database and files? [y/N] " answer
    [[ "$answer" =~ ^[yY]$ ]] || exit 0
  fi
  shared_network disconnect
  compose down -v --remove-orphans
  rm -rf "${BOXES_DIR:?}/$NAME"
  rm -f "$CACHE_DIR/certs/$NAME.pem" "$CACHE_DIR/certs/$NAME-key.pem"
  ok "Removed '$NAME'"
}

# Print all boxes with platform, version, address and status; --size adds the disk size of boxes/<name>: cmd_list [--size]
# shellcheck disable=SC2120
cmd_list() {
  local f running size="" sizes=()
  running=" $(docker ps --filter label=com.docker.compose.project --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | sort -u | paste -sd' ') "
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

# Print the addresses and credentials of a box: cmd_info <name>
cmd_info() { load_env "${1:-}"; print_info; print_stack; }

# Print the versions a platform can install: cmd_versions <platform>
cmd_versions() { [[ -n "${1:-}" ]] || die "Usage: phpbox versions <platform> ($(platforms))"; load_platform "$1"; p_versions; }

# Open a shell in the php or the given service container: cmd_shell <name> [service]
cmd_shell() { load_env "${1:-}"; compose exec "${2:-php}" sh -c 'command -v bash >/dev/null && exec bash || exec sh'; }

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
