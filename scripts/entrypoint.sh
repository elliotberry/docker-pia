#!/usr/bin/env bash
#
# docker-pia entrypoint (runs as PID 2 under tini).
#   1. prepare the container (timezone, user, state, kill switch)
#   2. connect to PIA over WireGuard (with retries)
#   3. run app-setup.sh as root, then app-startup.sh as PUID:PGID
#   4. supervise the tunnel and the forwarded port until the app exits or we get SIGTERM

set -Eeuo pipefail

# shellcheck source=lib/pia.sh
source /opt/scripts/lib/pia.sh

APP_UID=
APP_GID=
app_pid=
sup_pid=

preflight() {
    [[ $EUID -eq 0 ]] || die "must run as root; the application is started as PUID:PGID"
    ip link add pia-preflight type wireguard 2> /dev/null || die \
        "cannot create a WireGuard interface. Run with --cap-add NET_ADMIN on a host whose kernel supports WireGuard (Linux 5.6+)."
    ip link del pia-preflight
    [[ -r $PIA_CA_CERT ]] || die "missing CA certificate $PIA_CA_CERT"
    mkdir -p "$PIA_RUN_DIR"
    rm -f "$PIA_RUN_DIR/app_started"
}

setup_timezone() {
    if [[ -n ${TZ:-} && -f /usr/share/zoneinfo/$TZ ]]; then
        ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
        printf '%s\n' "$TZ" > /etc/timezone
    elif [[ -n ${TZ:-} ]]; then
        warn "unknown timezone '$TZ'; using UTC"
    fi
}

setup_user() {
    APP_UID=${PUID:-1000}
    APP_GID=${PGID:-1000}
    [[ $APP_UID =~ ^[0-9]+$ && $APP_GID =~ ^[0-9]+$ ]] || die "PUID and PGID must be numeric"

    local group
    if ((APP_GID != 0)) && ! getent group "$APP_GID" > /dev/null; then
        addgroup -g "$APP_GID" docker_group
    fi
    group=$(getent group "$APP_GID" | cut -d: -f1)
    if ((APP_UID != 0)) && ! getent passwd "$APP_UID" > /dev/null; then
        adduser -D -H -h /config -u "$APP_UID" -G "$group" -s /sbin/nologin docker_user
    fi

    if ((APP_UID != 0)); then
        APP_PREFIX=(su-exec "$APP_UID:$APP_GID")
    else
        warn "running the application as root; the kill switch bootstrap exceptions then also apply to it"
    fi

    # Only fix ownership when the top level is wrong; a recursive chown on every
    # start is slow on large volumes.
    if [[ -d /config && $(stat -c '%u:%g' /config) != "$APP_UID:$APP_GID" ]]; then
        log "fixing ownership of /config"
        chown -R "$APP_UID:$APP_GID" /config
    fi

    # Root-only state (cached port-forward signature) lives inside /config.
    if [[ -d /config ]]; then
        mkdir -p "$PIA_STATE_DIR"
        chown 0:0 "$PIA_STATE_DIR"
        chmod 700 "$PIA_STATE_DIR"
    fi
}

load_credentials() {
    load_secret PIA_USERNAME
    load_secret PIA_PASSWORD
    [[ -n $PIA_USERNAME && -n $PIA_PASSWORD ]] ||
        die "set PIA_USERNAME and PIA_PASSWORD (or PIA_USERNAME_FILE and PIA_PASSWORD_FILE)"
}

stop_children() {
    [[ -n $sup_pid ]] && kill -TERM "$sup_pid" 2> /dev/null || true
    if [[ -n $app_pid ]] && kill -0 "$app_pid" 2> /dev/null; then
        kill -TERM "$app_pid" 2> /dev/null || true
        wait "$app_pid" 2> /dev/null || true
    fi
    pia_wg_down
}

# shellcheck disable=SC2329  # invoked through trap
on_signal() {
    trap - TERM INT
    log "received a stop signal; shutting down"
    stop_children
    exit 143
}

main() {
    log "docker-pia ${IMAGE_VERSION:-dev} starting"
    preflight
    setup_timezone
    setup_user
    load_credentials
    trap on_signal TERM INT

    net_capture_default
    killswitch_enable

    pia_connect_with_retry || die "could not connect to PIA after $PIA_CONNECT_RETRIES attempts"

    VPN_PORT=Inactive
    if is_true "$PIA_PORT_FORWARD" && [[ -f $PIA_RUN_DIR/vpn_port ]]; then
        VPN_PORT=$(<"$PIA_RUN_DIR/vpn_port")
    else
        printf '%s\n' "$VPN_PORT" > "$PIA_RUN_DIR/vpn_port"
    fi
    export VPN_PORT
    log "VPN_PORT=$VPN_PORT"

    # Keep the tunnel and the forwarded port alive in the background.
    pia_supervisor &
    sup_pid=$!

    log "running app-setup.sh"
    /opt/scripts/app-setup.sh || { stop_children; die "app-setup.sh failed"; }

    log "starting app-startup.sh as ${APP_UID}:${APP_GID}"
    local -a app_cmd=(env -u PIA_USERNAME -u PIA_PASSWORD -u PIA_USERNAME_FILE -u PIA_PASSWORD_FILE
        HOME=/config "VPN_PORT=$VPN_PORT" /opt/scripts/app-startup.sh)
    if ((${#APP_PREFIX[@]})); then
        app_cmd=("${APP_PREFIX[@]}" "${app_cmd[@]}")
    fi
    "${app_cmd[@]}" &
    app_pid=$!
    touch "$PIA_RUN_DIR/app_started"

    local rc=0
    wait -n "$app_pid" "$sup_pid" || rc=$?
    if kill -0 "$app_pid" 2> /dev/null; then
        warn "the VPN supervisor stopped; shutting down"
        rc=1
    else
        log "the application exited with status $rc"
    fi
    stop_children
    exit "$rc"
}

main "$@"
