# shellcheck shell=bash disable=SC2034

# Run docker compose for the loaded box with its platform overlays, services, image tags and variables: compose <args...>
compose() {
  local files=(-f "$ROOT/docker/compose.yml") f s tags
  for f in "${P_COMPOSE[@]}"; do files+=(-f "$f"); done
  for s in $SERVICES; do files+=(-f "$ROOT/docker/services/${s%%:*}.yml"); done
  mapfile -t tags < <(service_tags)
  [[ -f "$BOXES_DIR/$NAME/compose.yml" ]] && files+=(-f "$BOXES_DIR/$NAME/compose.yml")
  mkdir -p "$BOXES_DIR/$NAME/nginx"
  ENV_DIR="$BOXES_DIR/$NAME" WWW_DIR="$WWW_DIR" CACHE_DIR="$CACHE_DIR" NGINX_CONF="$P_NGINX_CONF" \
  HTTP_PORT="$HTTP_PORT" HTTPS_PORT="$HTTPS_PORT" RABBITMQ_PORT=$((PORT + 20000)) \
  PHP_IMAGE="$PHP_IMAGE" CRON_COMMAND="$P_CRON" \
  DB_NAME="$DB_NAME" DB_USER="$DB_USER" DB_PASS="$DB_PASS" DB_ROOT_PASS="$DB_ROOT_PASS" \
  ADMIN_USER="$ADMIN_USER" ADMIN_EMAIL="$ADMIN_EMAIL" ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    env "${tags[@]}" docker compose -p "phpbox-$NAME" --env-file "$ENV_FILE" "${files[@]}" "$@"
}

# Run a shell script from stdin in the php container as the host user; commands in it get no stdin: php_run [-e K=V...]
php_run() {
  local script
  script=$(cat)
  compose exec -T "$@" php bash -c "$script" </dev/null
}

# Run docker compose for the shared proxy, Mailpit and phpMyAdmin from docker/shared.yml: shared <args...>
shared() {
  mkdir -p "$BOXES_DIR" "$CACHE_DIR/certs"
  HTTP_PORT="$HTTP_PORT" HTTPS_PORT="$HTTPS_PORT" MAILPIT_PORT="$MAILPIT_PORT" PHPMYADMIN_PORT="$PHPMYADMIN_PORT" \
  DB_ROOT_PASS="$DB_ROOT_PASS" CACHE_DIR="$CACHE_DIR" BOXES_DIR="$BOXES_DIR" \
    docker compose -p phpbox -f "$ROOT/docker/shared.yml" "$@"
}

# Start the shared containers; a busy port stops phpbox with the docker message.
shared_up() {
  local out
  out=$(shared up -d 2>&1) || die "Shared containers did not start (ports in phpbox.conf):"$'\n'"$out"
}

# Connect or disconnect phpbox-proxy and phpbox-phpmyadmin to the box network: shared_network <connect|disconnect>
shared_network() {
  local c force=()
  [[ "$1" == disconnect ]] && force=(-f)
  for c in phpbox-proxy phpbox-phpmyadmin; do
    docker network "$1" "${force[@]}" "phpbox-${NAME}_default" "$c" 2>/dev/null || true
  done
}

# Start the loaded box: tools, certificate, shared containers, box containers, network links.
box_up() {
  ensure_tools
  ensure_cert
  shared_up
  compose up -d --wait "$@"
  shared_network connect
}

# Stop the loaded box and remove its containers; volumes stay.
box_down() {
  shared_network disconnect
  compose down --remove-orphans
}

# Return 0 when the box has a running container: box_running <name>
box_running() { [[ -n "$(docker compose -p "phpbox-$1" ps -q --status running 2>/dev/null)" ]]; }

# Return 0 when the box has any container, running or not: box_exists <name>
box_exists() { [[ -n "$(docker compose -p "phpbox-$1" ps -aq 2>/dev/null)" ]]; }

# Return 0 when the shared proxy container is running.
shared_running() { [[ -n "$(docker ps -q --filter name='^phpbox-proxy$' 2>/dev/null)" ]]; }

# Download a file once and make it executable: download <path> <url>
download() {
  [[ -x "$1" ]] && return 0
  log "Downloading $(basename "$1")…"
  curl -fsSL -o "$1.part" "$2" && chmod +x "$1.part" && mv "$1.part" "$1"
}

# Put composer, wp-cli, mailpit and mkcert into cache/bin and prepare the CA.
ensure_tools() {
  local cid
  mkdir -p "$BIN_DIR" "$CACHE_DIR/composer" "$CACHE_DIR/wp-cli"
  download "$BIN_DIR/composer" https://getcomposer.org/download/latest-stable/composer.phar
  download "$BIN_DIR/wp" https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  if [[ ! -x "$BIN_DIR/mailpit" ]]; then
    log "Downloading mailpit…"
    cid=$(docker create axllent/mailpit:latest)
    docker cp "$cid:/mailpit" "$BIN_DIR/mailpit" >/dev/null
    docker rm "$cid" >/dev/null
  fi
  ensure_ca
}

# Write boxes/<name>/compose.yml giving the php container the host SSH keys and agent.
write_ssh_override() {
  local agent="" volumes=()
  [[ -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]] && agent="$SSH_AUTH_SOCK"
  [[ -d "$HOME/.ssh" ]] && volumes+=("$HOME/.ssh:$HOME/.ssh:ro")
  [[ -n "$agent" ]] && volumes+=("$agent:/ssh-agent")
  {
    printf 'services:\n  php:\n'
    if [[ -n "$agent" ]]; then printf '    environment:\n      SSH_AUTH_SOCK: /ssh-agent\n'; fi
    if [[ ${#volumes[@]} -gt 0 ]]; then printf '    volumes:\n'; printf '      - %s\n' "${volumes[@]}"; fi
  } > "$BOXES_DIR/$NAME/compose.yml"
}
