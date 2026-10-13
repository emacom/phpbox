# shellcheck shell=bash disable=SC2034

# Run the mariadb client as root in the db container: db_exec [mariadb options]
db_exec() { compose exec -T db mariadb -uroot -p"$DB_ROOT_PASS" "$@"; }

# Recreate the box database and import SQL from stdin: db_load [mariadb options]
db_load() {
  db_exec -e "DROP DATABASE IF EXISTS \`$DB_NAME\`; CREATE DATABASE \`$DB_NAME\`;" </dev/null
  db_exec "$@" "$DB_NAME"
}

# Print a gzip-compressed dump of the box database.
db_dump() {
  compose exec -T db mariadb-dump -uroot -p"$DB_ROOT_PASS" --single-transaction --routines --triggers "$DB_NAME" | gzip -1
}

# Decompress stdin by the extension of the dump file: dump_decompress <file>
dump_decompress() {
  case "$1" in
    *.gz)  gunzip -c ;;
    *.zst) zstd -dc ;;
    *.bz2) bunzip2 -c ;;
    *)     cat ;;
  esac
}

# Make a MySQL 8 dump importable into MariaDB: collations, definers, version comments, GTID.
dump_fix() {
  sed -E \
    -e 's/utf8mb4_0900_[a-z_]+/utf8mb4_unicode_ci/g' \
    -e 's/DEFINER=`[^`]*`@`[^`]*`//g' \
    -e 's#/\*!80[0-9]{3} [^*]*\*/##g' \
    -e '/^SET @@GLOBAL.GTID_PURGED/,/;$/d'
}

# Print rsync --exclude options for the platform paths left out of snapshots.
snapshot_excludes() { local e; for e in $(p_snapshot_excludes); do printf -- '--exclude=/%s ' "$e"; done; }

# Save the database and, for installed boxes, www/ into boxes/<name>/snapshot.
take_snapshot() {
  local dir="$BOXES_DIR/$NAME/snapshot"
  mkdir -p "$dir"
  log "Database snapshot…"
  db_dump > "$dir/db.sql.gz.tmp"
  if [[ "$KIND" != project ]]; then
    log "Files snapshot…"
    # shellcheck disable=SC2046
    rsync -a --delete $(snapshot_excludes) "$WWW_DIR/" "$dir/www/"
  fi
  mv "$dir/db.sql.gz.tmp" "$dir/db.sql.gz"
  date '+%F %T' > "$dir/created_at"
  ok "Snapshot saved ($(du -sh "$dir" | cut -f1))"
}
