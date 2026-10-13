# shellcheck shell=bash disable=SC2034

# Install mkcert, trust its CA once and build cache/certs/ca-bundle.pem for php containers.
ensure_ca() {
  local caroot arch certs="$CACHE_DIR/certs" system host
  MKCERT=$(command -v mkcert || echo "$BIN_DIR/mkcert")
  if [[ ! -x "$MKCERT" ]]; then
    case "$(uname -m)" in
      x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) die "mkcert: unsupported architecture $(uname -m)" ;;
    esac
    download "$MKCERT" "https://dl.filippo.io/mkcert/latest?for=linux/$arch"
  fi
  caroot=$("$MKCERT" -CAROOT)
  if [[ ! -f "$caroot/rootCA.pem" ]]; then
    command -v certutil >/dev/null || log "Chrome and Firefox need certutil to trust the CA: sudo apt install libnss3-tools, then: $MKCERT -install"
    log "Creating local CA and adding it to the system trust store (sudo)…"
    "$MKCERT" -install || log "CA not trusted; browsers will warn about certificates. Retry: $MKCERT -install"
  fi
  mkdir -p "$certs"
  if [[ ! -s "$certs/ca-bundle.pem" || "$caroot/rootCA.pem" -nt "$certs/ca-bundle.pem" ]]; then
    for system in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt ""; do [[ -f "$system" ]] && break; done
    [[ -n "$system" ]] || die "System CA bundle not found"
    cat "$system" "$caroot/rootCA.pem" > "$certs/ca-bundle.pem"
  fi
  [[ -f "$certs/_.pem" ]] || issue_cert _ localhost
  for host in $SHARED_HOSTS; do
    [[ -f "$certs/$host.pem" ]] || issue_cert "$host" "$host.localhost"
  done
}

# Issue the certificate of the loaded box for <name>.localhost and *.<name>.localhost once.
ensure_cert() { [[ -f "$CACHE_DIR/certs/$NAME.pem" ]] || issue_cert "$NAME" "$NAME.localhost" "*.$NAME.localhost"; }

# Write cache/certs/<file>.pem and <file>-key.pem readable by the proxy: issue_cert <file> <host...>
issue_cert() {
  local f="$CACHE_DIR/certs/$1"; shift
  "$MKCERT" -cert-file "$f.pem" -key-file "$f-key.pem" "$@" >/dev/null 2>&1 || die "mkcert failed for $*"
  chmod 644 "$f-key.pem"
}
