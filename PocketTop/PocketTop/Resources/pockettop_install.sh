#!/usr/bin/env bash
# PocketTop server-side installer.
#
# This script is uploaded to a Linux host by the iOS app, along with the
# pre-built pockettopd Go binary (already placed at /tmp/pockettopd before
# this script runs). It installs, configures, and starts the pockettopd
# systemd service with a self-signed TLS cert and a random bearer API key.
#
# Subcommands: preflight | install | upgrade | status | uninstall
#
# Output contract: ONLY JSON lines go to stdout. Free-form diagnostics go
# to stderr (the iOS side ignores stderr). Each install step emits a
# "started" and a "completed" JSON line. On error, a single {"error":...}
# line is printed and the script exits 1.

set -u
set -o pipefail

POCKETTOP_VERSION="1.0.0"

INSTALL_ROOT="/opt/pockettop"
BIN_DIR="${INSTALL_ROOT}/bin"
CERT_DIR="${INSTALL_ROOT}/certs"
CERT_PATH="${CERT_DIR}/server.crt"
KEY_PATH="${CERT_DIR}/server.key"
API_KEY_PATH="${INSTALL_ROOT}/.api_key"
BINARY_SRC="/tmp/pockettopd"
BINARY_DST="${BIN_DIR}/pockettopd"
SERVICE_NAME="pockettopd"
SERVICE_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
# HTTPS_PORT starts as a placeholder; cmd_install / cmd_upgrade override it
# via `pick_port` after probing what's actually free on this host. 443 is
# first choice but docker-proxy / reverse proxies routinely own it, so we
# fall back to alt-HTTPS ports.
HTTPS_PORT=443
PORT_CANDIDATES="443 8443 9443 18443"

# ---------- helpers ----------

# Emit a JSON progress line to stdout.
emit_json() {
    printf '%s\n' "$1"
}

# Emit an error JSON line and exit.
fail() {
    local msg="$1"
    # Escape backslashes and double quotes for safe JSON.
    msg="${msg//\\/\\\\}"
    msg="${msg//\"/\\\"}"
    printf '{"error":"%s"}\n' "$msg"
    exit 1
}

# Emit "step started" line.
step_start() {
    local step="$1"
    local message="$2"
    message="${message//\\/\\\\}"
    message="${message//\"/\\\"}"
    printf '{"step":"%s","status":"started","message":"%s"}\n' "$step" "$message"
}

# Emit "step completed" line.
step_done() {
    local step="$1"
    printf '{"step":"%s","status":"completed"}\n' "$step"
}

# Log to stderr so it never contaminates the JSON stdout channel.
log() {
    printf '%s\n' "$*" >&2
}

# Require a prerequisite binary. Fail hard with a structured error if missing.
require_bin() {
    local name="$1"
    if ! command -v "$name" >/dev/null 2>&1; then
        fail "missing prerequisite: $name"
    fi
}

# Detect which user's home to treat as the "client" user's cache target.
# When run under sudo, $SUDO_USER is set to the invoking (non-root) user
# and that's where ~/.pockettop should live. When run directly as root
# (e.g. from systemd or a root shell), fall back to root's home so the
# script still works, though the iOS flow always goes through sudo.
client_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        printf '%s' "${SUDO_USER}"
    else
        printf '%s' "${USER:-root}"
    fi
}

client_home() {
    local user
    user="$(client_user)"
    if [ "$user" = "root" ]; then
        printf '%s' "/root"
    else
        # getent is safe on Debian/Ubuntu; fall back to /home/<user>.
        local home
        home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
        if [ -z "$home" ]; then
            home="/home/${user}"
        fi
        printf '%s' "$home"
    fi
}

# Return 0 if TCP port "$1" is bound locally on any interface, 1 otherwise.
# `ss` is present on every systemd-based distro we support; we match the
# last field of the Local-Address column which is always `addr:port` or
# `[addr]:port`, so anchoring on `:PORT$` is correct regardless of IPv4/v6.
port_in_use() {
    local p="$1"
    ss -tln 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE "[:.]${p}\$"
}

# Pick the first free port from PORT_CANDIDATES and assign it to HTTPS_PORT.
# Returns non-zero (caller should `fail`) if none are free.
pick_port() {
    local p
    for p in $PORT_CANDIDATES; do
        if ! port_in_use "$p"; then
            HTTPS_PORT="$p"
            log "picked HTTPS port: $p"
            return 0
        fi
    done
    return 1
}

# Detect the public IPv4 for use in the cert SAN. Tries external reflectors
# first, falls back to the first hostname -I address. stderr is silenced so
# curl's progress/error text never leaks to stdout JSON.
detect_public_ip() {
    local ip=""
    ip="$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [ -z "$ip" ]; then
        ip="$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    fi
    if [ -z "$ip" ]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    # Basic sanity: must look like a dotted-quad; otherwise empty so caller
    # can decide to fail or proceed with 127.0.0.1 only (we fail below).
    if ! printf '%s' "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        ip=""
    fi
    printf '%s' "$ip"
}

# ---------- subcommands ----------

cmd_preflight() {
    local os="unknown"
    local arch
    local disk_free_kb=0
    local sudo_mode="unknown"
    local internet="false"
    local uid

    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        os="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-unknown}")"
    fi

    arch="$(uname -m 2>/dev/null || echo unknown)"

    if command -v df >/dev/null 2>&1; then
        disk_free_kb="$(df -k /opt 2>/dev/null | awk 'NR==2 {print $4}')"
        if [ -z "$disk_free_kb" ]; then
            disk_free_kb=0
        fi
    fi

    uid="$(id -u 2>/dev/null || echo 1000)"
    if [ "$uid" = "0" ]; then
        sudo_mode="root"
    elif command -v sudo >/dev/null 2>&1; then
        sudo_mode="sudo"
    else
        sudo_mode="none"
    fi

    if curl -4 -s --max-time 5 -o /dev/null -w '%{http_code}' https://api.ipify.org 2>/dev/null | grep -q '^2'; then
        internet="true"
    fi

    # Emit a single JSON object. No pretty printing.
    printf '{"os":"%s","arch":"%s","disk_free_kb":%s,"sudo":"%s","internet":%s,"version":"%s"}\n' \
        "$os" "$arch" "$disk_free_kb" "$sudo_mode" "$internet" "$POCKETTOP_VERSION"
    return 0
}

cmd_install() {
    # Prereqs: we do NOT apt-install anything. These should already exist
    # on any sane Debian/Ubuntu. Missing = hard fail with structured error.
    require_bin openssl
    require_bin curl
    require_bin ss
    # ufw is optional — we skip firewall config if it's absent.
    # systemctl is required (we're installing a systemd service).
    require_bin systemctl

    # Uploaded binary must be present.
    if [ ! -f "$BINARY_SRC" ]; then
        fail "pockettopd binary not found at $BINARY_SRC"
    fi

    # Decide which port we're going to bind. Done BEFORE cleanup so if
    # none of the candidates are free we fail fast without tearing down
    # the previous install. An existing pockettopd on $HTTPS_PORT is fine
    # (cleanup stops it first); anything else on 443/8443/... means we
    # fall through to the next candidate.
    # We treat our own SERVICE_NAME as not-in-use for the first-choice
    # port: cleanup will stop it before we try to bind again.
    if systemctl is-active "${SERVICE_NAME}.service" >/dev/null 2>&1; then
        systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    fi
    if ! pick_port; then
        fail "no free HTTPS port available (tried: ${PORT_CANDIDATES})"
    fi

    # --- Step 1: cleanup ---
    step_start "cleanup" "Removing previous install"
    if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}.service"; then
        systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
        systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
    fi
    rm -f "$SERVICE_UNIT" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$INSTALL_ROOT" 2>/dev/null || true
    # Kill any orphan pockettopd not managed by systemd (old run, crashed, etc).
    pkill -x pockettopd 2>/dev/null || true
    step_done "cleanup"

    # --- Step 2: firewall ---
    step_start "firewall" "Configuring UFW rules (port ${HTTPS_PORT})"
    if command -v ufw >/dev/null 2>&1; then
        # Only add rules. Do not call `ufw enable` — the ref doc's advice
        # is to respect the operator's existing state. If ufw is inactive
        # these rules are recorded but dormant; if it's active they take
        # effect immediately.
        ufw allow OpenSSH 2>/dev/null || true
        ufw allow "${HTTPS_PORT}/tcp" 2>/dev/null || true
    fi
    step_done "firewall"

    # --- Step 3: directories ---
    step_start "directories" "Creating install directories"
    mkdir -p "$BIN_DIR" "$CERT_DIR" 2>/dev/null || fail "could not create $INSTALL_ROOT tree"
    chown -R root:root "$INSTALL_ROOT" 2>/dev/null || true
    chmod 755 "$INSTALL_ROOT" "$BIN_DIR" "$CERT_DIR" 2>/dev/null || true

    local user home cache_dir
    user="$(client_user)"
    home="$(client_home)"
    cache_dir="${home}/.pockettop"
    mkdir -p "$cache_dir" 2>/dev/null || fail "could not create user cache dir $cache_dir"
    chmod 700 "$cache_dir" 2>/dev/null || true
    if [ "$user" != "root" ]; then
        chown "$user:$user" "$cache_dir" 2>/dev/null || true
    fi
    step_done "directories"

    # --- Step 4: binary ---
    step_start "binary" "Installing pockettopd binary"
    mv "$BINARY_SRC" "$BINARY_DST" 2>/dev/null || fail "could not move binary into place"
    chmod +x "$BINARY_DST" 2>/dev/null || fail "could not chmod binary"
    chown root:root "$BINARY_DST" 2>/dev/null || true
    step_done "binary"

    # --- Step 5: api key ---
    step_start "apikey" "Generating API key"
    local api_key
    api_key="$(openssl rand -hex 32 2>/dev/null)"
    if [ -z "$api_key" ]; then
        fail "openssl rand failed"
    fi
    # Use a tmp file + mv so the final file only ever exists with correct perms.
    umask 077
    printf '%s' "$api_key" > "$API_KEY_PATH" || fail "could not write api key"
    chmod 600 "$API_KEY_PATH" 2>/dev/null || true
    chown root:root "$API_KEY_PATH" 2>/dev/null || true
    step_done "apikey"

    # --- Step 6: self-signed cert with IP SAN ---
    step_start "cert" "Generating self-signed certificate"
    local server_ip
    server_ip="$(detect_public_ip)"
    if [ -z "$server_ip" ]; then
        fail "could not detect public IP for certificate SAN"
    fi
    # EC prime256v1 key + 10-year cert. SAN must include both the public IP
    # (so iOS 14+ clients accept it — CN alone is ignored) and 127.0.0.1
    # (so the in-process health check loop below works without dns).
    local san
    if [ "$server_ip" = "127.0.0.1" ]; then
        san="IP:127.0.0.1"
    else
        san="IP:${server_ip},IP:127.0.0.1"
    fi
    if ! openssl req -x509 \
            -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -nodes \
            -keyout "$KEY_PATH" \
            -out "$CERT_PATH" \
            -days 3650 \
            -subj "/CN=pockettop" \
            -addext "subjectAltName=${san}" \
            >/dev/null 2>&1; then
        fail "openssl cert generation failed"
    fi
    # Cert is PUBLIC info — non-root SSH user needs to read it during the
    # installer's post-install verify step (`openssl x509 -fingerprint ...`).
    # Only the private key needs to be root-only.
    chmod 644 "$CERT_PATH" 2>/dev/null || true
    chmod 600 "$KEY_PATH" 2>/dev/null || true
    chown root:root "$CERT_PATH" "$KEY_PATH" 2>/dev/null || true
    step_done "cert"

    # --- Step 7: user-readable cache (api key + cert fingerprint) ---
    step_start "cache" "Writing user-readable credential cache"
    local fp
    fp="$(openssl x509 -fingerprint -sha256 -noout -in "$CERT_PATH" 2>/dev/null \
            | sed -e 's/^SHA256 Fingerprint=//' -e 's/://g' \
            | tr 'A-Z' 'a-z')"
    if [ -z "$fp" ]; then
        fail "could not compute cert fingerprint"
    fi

    printf '%s' "$api_key" > "${cache_dir}/api_key" || fail "could not write cache api_key"
    printf '%s' "$fp" > "${cache_dir}/cert_fp" || fail "could not write cache cert_fp"
    chmod 600 "${cache_dir}/api_key" "${cache_dir}/cert_fp" 2>/dev/null || true
    if [ "$user" != "root" ]; then
        chown "$user:$user" "${cache_dir}/api_key" "${cache_dir}/cert_fp" 2>/dev/null || true
    fi
    step_done "cache"

    # --- Step 8: systemd unit ---
    step_start "systemd" "Installing systemd unit"
    cat > "$SERVICE_UNIT" <<EOF || fail "could not write $SERVICE_UNIT"
[Unit]
Description=PocketTop metrics & action agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_ROOT}
ExecStart=${BINARY_DST} --cert ${CERT_PATH} --key ${KEY_PATH} --api-key-file ${API_KEY_PATH} --port ${HTTPS_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_UNIT" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || fail "systemctl daemon-reload failed"
    systemctl enable --now "${SERVICE_NAME}.service" 2>/dev/null \
        || fail "systemctl enable --now ${SERVICE_NAME} failed"
    step_done "systemd"

    # --- Step 9: health check ---
    step_start "health" "Waiting for agent to become healthy"
    local deadline=$(( $(date +%s) + 30 ))
    local healthy="false"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        # -k = --insecure. We only care that pockettopd is answering on 443
        # — the cert pin check belongs to the iOS client.
        local code
        code="$(curl -k -s -o /dev/null -w '%{http_code}' \
                    --max-time 2 \
                    "https://127.0.0.1:${HTTPS_PORT}/health" 2>/dev/null || echo "000")"
        if [ "$code" = "200" ]; then
            healthy="true"
            break
        fi
        sleep 1
    done
    if [ "$healthy" != "true" ]; then
        fail "health check timed out"
    fi
    step_done "health"

    # --- Final success line ---
    printf '{"result":"success","api_key":"%s","cert_fingerprint":"%s","https_port":%s,"version":"%s"}\n' \
        "$api_key" "$fp" "$HTTPS_PORT" "$POCKETTOP_VERSION"
    return 0
}

cmd_upgrade() {
    # Upgrade = reinstall the pre-uploaded binary and restart the service.
    # Cert and api key are preserved; version reported is bumped.
    require_bin systemctl
    if [ ! -f "$BINARY_SRC" ]; then
        fail "pockettopd binary not found at $BINARY_SRC"
    fi
    if [ ! -d "$INSTALL_ROOT" ]; then
        fail "pockettop is not installed; run install instead"
    fi

    # Preserve whichever port the previous install chose — we can read it
    # back off the systemd unit's `--port N` argument. If parsing fails
    # (hand-edited unit?), fall through with the script's default.
    local existing_port
    existing_port="$(grep -oE -- '--port [0-9]+' "$SERVICE_UNIT" 2>/dev/null \
                        | awk '{print $2}' \
                        | head -n1)"
    if [ -n "$existing_port" ]; then
        HTTPS_PORT="$existing_port"
        log "upgrading on port $HTTPS_PORT"
    fi

    step_start "binary" "Replacing pockettopd binary"
    systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    pkill -x pockettopd 2>/dev/null || true
    mv "$BINARY_SRC" "$BINARY_DST" 2>/dev/null || fail "could not move binary into place"
    chmod +x "$BINARY_DST" 2>/dev/null || fail "could not chmod binary"
    chown root:root "$BINARY_DST" 2>/dev/null || true
    step_done "binary"

    step_start "systemd" "Restarting systemd service"
    systemctl daemon-reload 2>/dev/null || true
    systemctl start "${SERVICE_NAME}.service" 2>/dev/null \
        || fail "systemctl start ${SERVICE_NAME} failed"
    step_done "systemd"

    step_start "health" "Waiting for agent to become healthy"
    local deadline=$(( $(date +%s) + 30 ))
    local healthy="false"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local code
        code="$(curl -k -s -o /dev/null -w '%{http_code}' \
                    --max-time 2 \
                    "https://127.0.0.1:${HTTPS_PORT}/health" 2>/dev/null || echo "000")"
        if [ "$code" = "200" ]; then
            healthy="true"
            break
        fi
        sleep 1
    done
    if [ "$healthy" != "true" ]; then
        fail "health check timed out"
    fi
    step_done "health"

    printf '{"result":"success","https_port":%s,"version":"%s"}\n' "$HTTPS_PORT" "$POCKETTOP_VERSION"
    return 0
}

cmd_status() {
    local installed="false"
    local active="inactive"
    local enabled="disabled"

    if [ -x "$BINARY_DST" ] && [ -f "$API_KEY_PATH" ] && [ -f "$CERT_PATH" ]; then
        installed="true"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        active="$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || echo "inactive")"
        enabled="$(systemctl is-enabled "${SERVICE_NAME}.service" 2>/dev/null || echo "disabled")"
    fi

    printf '{"installed":%s,"version":"%s","services":{"%s":{"active":"%s","enabled":"%s"}}}\n' \
        "$installed" "$POCKETTOP_VERSION" "$SERVICE_NAME" "$active" "$enabled"
    return 0
}

cmd_uninstall() {
    step_start "systemd" "Stopping and disabling service"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
        systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
        rm -f "$SERVICE_UNIT" 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    fi
    pkill -x pockettopd 2>/dev/null || true
    step_done "systemd"

    step_start "cleanup" "Removing installed files"
    rm -rf "$INSTALL_ROOT" 2>/dev/null || true
    # Also drop the per-user cache dir — it's useless without the server.
    local user home cache_dir
    user="$(client_user)"
    home="$(client_home)"
    cache_dir="${home}/.pockettop"
    rm -rf "$cache_dir" 2>/dev/null || true
    step_done "cleanup"

    step_start "firewall" "Revoking UFW rules"
    if command -v ufw >/dev/null 2>&1; then
        # Idempotent: `ufw delete allow` is a no-op if the rule doesn't exist.
        # We don't know which candidate the install actually bound to, so
        # sweep all of them.
        local p
        for p in $PORT_CANDIDATES; do
            ufw delete allow "${p}/tcp" 2>/dev/null || true
        done
        # Leave `OpenSSH` allow rule in place — removing it could lock the
        # operator out of their own box. The reference doc warns about this.
    fi
    step_done "firewall"

    printf '{"result":"success"}\n'
    return 0
}

# ---------- dispatch ----------

main() {
    local sub="${1:-}"
    case "$sub" in
        preflight)
            cmd_preflight
            ;;
        install)
            cmd_install
            ;;
        upgrade)
            cmd_upgrade
            ;;
        status)
            cmd_status
            ;;
        uninstall)
            cmd_uninstall
            ;;
        version|--version|-v)
            printf '{"version":"%s"}\n' "$POCKETTOP_VERSION"
            ;;
        "")
            fail "no subcommand given; expected one of: preflight install upgrade status uninstall"
            ;;
        *)
            fail "unknown subcommand: $sub"
            ;;
    esac
}

main "$@"
