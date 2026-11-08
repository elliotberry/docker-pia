#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
#
# docker-pia shared library. Sourced by entrypoint.sh and health-check.sh.
# It has no side effects when sourced: it only sets defaults and defines functions.
#
# The connection flow follows PIA's documented "manual connections" protocol:
#   1. POST credentials          -> API token
#   2. GET server list (v6)      -> regions and WireGuard servers
#   3. GET <server>:1337/addKey  -> register our public key, receive peer details
#   4. configure the wg interface and routes
#   5. (optional) <gateway>:19999/getSignature + bindPort -> forwarded port

# ---------------------------------------------------------------------------
# Defaults (all overridable through the environment)
# ---------------------------------------------------------------------------
: "${PIA_IFACE:=pia}"
: "${PIA_REGION:=${PIA_LOCATION:-auto}}"   # PIA_LOCATION is a deprecated alias
: "${PIA_PORT_FORWARD:=false}"
: "${PIA_KILLSWITCH:=true}"
: "${PIA_DNS:=true}"
: "${PIA_MTU:=1420}"
: "${PIA_DEBUG_LOGGING:=false}"
: "${LOCAL_NETWORKS:=}"
: "${PIA_HANDSHAKE_TIMEOUT:=180}"          # seconds without a handshake before the tunnel is stale
: "${PIA_CHECK_INTERVAL:=10}"              # supervisor poll interval in seconds
: "${PIA_PF_INTERVAL:=900}"                # port-forward keepalive (PIA requires <= 15 minutes)
: "${PIA_CONNECT_RETRIES:=5}"              # connect attempts before the container gives up
: "${PIA_HEALTH_URL:=https://1.1.1.1/cdn-cgi/trace}"
: "${PIA_STATE_DIR:=/config/.pia}"

PIA_RUN_DIR=/run/pia
PIA_CA_CERT=/opt/pia/ca.rsa.4096.crt
PIA_TOKEN_URL=https://www.privateinternetaccess.com/api/client/v2/token
PIA_SERVERLIST_URL=https://serverlist.piaservers.net/vpninfo/servers/v6

# ---------------------------------------------------------------------------
# Logging and small helpers
# ---------------------------------------------------------------------------
log()   { printf '%s [pia] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn()  { log "WARN: $*" >&2; }
die()   { log "ERROR: $*" >&2; exit 1; }
debug() { if is_true "$PIA_DEBUG_LOGGING"; then log "DEBUG: $*"; fi; return 0; }

is_true() {
    case "${1,,}" in
        true | 1 | yes | on) return 0 ;;
        *) return 1 ;;
    esac
}

# Escape a value for use inside a double-quoted curl config string.
cfg_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

# load_secret NAME: use $NAME_FILE (Docker/K8s secret) if set, otherwise $NAME.
load_secret() {
    local name=$1 file_var="${1}_FILE" value=
    if [[ -n ${!file_var:-} ]]; then
        [[ -r ${!file_var} ]] || die "${file_var} points to an unreadable file: ${!file_var}"
        value=$(<"${!file_var}")
    else
        value=${!name:-}
    fi
    printf -v "$name" '%s' "$value"
}

# ---------------------------------------------------------------------------
# Kill switch (iptables)
# ---------------------------------------------------------------------------
IPT=iptables
IPT6=ip6tables

ipt_detect() {
    if ! $IPT -S > /dev/null 2>&1 && command -v iptables-legacy > /dev/null 2>&1; then
        IPT=iptables-legacy
        IPT6=ip6tables-legacy
    fi
}

ipt6_usable() {
    if $IPT6 -S > /dev/null 2>&1; then
        return 0
    fi
    if command -v ip6tables-legacy > /dev/null 2>&1 && ip6tables-legacy -S > /dev/null 2>&1; then
        IPT6=ip6tables-legacy
        return 0
    fi
    return 1
}

# Networks that stay reachable outside the tunnel: the container's own
# subnets plus anything listed in LOCAL_NETWORKS.
pia_local_networks() {
    ip -4 -o route show scope link |
        awk -v i="$PIA_IFACE" '$3 != i && $1 ~ /\// { print $1 }'
    local n
    for n in ${LOCAL_NETWORKS//,/ }; do
        printf '%s\n' "$n"
    done
}

killswitch_enable() {
    is_true "$PIA_KILLSWITCH" || { warn "kill switch disabled: traffic can leak while the VPN is down"; return 0; }
    ipt_detect

    $IPT -N PIA_KS 2> /dev/null || $IPT -F PIA_KS
    $IPT -N PIA_EP 2> /dev/null || $IPT -F PIA_EP

    $IPT -A PIA_KS -o lo -j ACCEPT
    $IPT -A PIA_KS -o "$PIA_IFACE" -j ACCEPT
    $IPT -A PIA_KS -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    $IPT -A PIA_KS -j PIA_EP
    local net
    while read -r net; do
        if [[ -n $net ]]; then
            $IPT -A PIA_KS -d "$net" -j ACCEPT
        fi
    done < <(pia_local_networks)
    # Bootstrap traffic (token, server list, addKey, DNS) is only allowed for
    # root, which is our own tooling. The application runs as PUID/PGID.
    $IPT -A PIA_KS -m owner --uid-owner 0 -p tcp -m multiport --dports 443,1337 -j ACCEPT
    $IPT -A PIA_KS -m owner --uid-owner 0 -p udp --dport 53 -j ACCEPT
    $IPT -A PIA_KS -m owner --uid-owner 0 -p tcp --dport 53 -j ACCEPT
    $IPT -A PIA_KS -j DROP
    $IPT -C OUTPUT -j PIA_KS 2> /dev/null || $IPT -I OUTPUT 1 -j PIA_KS

    # The tunnel carries IPv4 only, so block IPv6 to avoid leaks.
    if ipt6_usable; then
        $IPT6 -N PIA_KS 2> /dev/null || $IPT6 -F PIA_KS
        $IPT6 -A PIA_KS -o lo -j ACCEPT
        $IPT6 -A PIA_KS -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        $IPT6 -A PIA_KS -j DROP
        $IPT6 -C OUTPUT -j PIA_KS 2> /dev/null || $IPT6 -I OUTPUT 1 -j PIA_KS
    else
        warn "ip6tables is unavailable; make sure IPv6 is disabled for this container"
    fi
    log "kill switch enabled"
}

# Allow the WireGuard UDP endpoint through the kill switch.
killswitch_endpoint() {
    is_true "$PIA_KILLSWITCH" || return 0
    $IPT -F PIA_EP && $IPT -A PIA_EP -d "$1" -p udp --dport "$2" -j ACCEPT
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
GWARGS=()
APP_PREFIX=()   # command prefix that drops privileges (set by entrypoint.sh)

# Remember how to reach the outside world before we touch any routes.
net_capture_default() {
    local line gw dev
    line=$(ip -4 route show default | sed -n '1p')
    [[ -n $line ]] || die "the container has no default route"
    gw=$(awk '{ for (i = 1; i < NF; i++) if ($i == "via") print $(i + 1) }' <<< "$line")
    dev=$(awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' <<< "$line")
    GWARGS=()
    [[ -n $gw ]] && GWARGS+=(via "$gw")
    GWARGS+=(dev "$dev")
}

pia_set_dns() {
    [[ -f $PIA_RUN_DIR/resolv.conf.orig ]] || cp /etc/resolv.conf "$PIA_RUN_DIR/resolv.conf.orig"
    printf 'nameserver %s\n' "$1" > /etc/resolv.conf || warn "could not write /etc/resolv.conf"
}

pia_restore_dns() {
    if [[ -f $PIA_RUN_DIR/resolv.conf.orig ]]; then
        cat "$PIA_RUN_DIR/resolv.conf.orig" > /etc/resolv.conf || true
    fi
}

pia_wg_down() {
    ip link del "$PIA_IFACE" 2> /dev/null || true   # also removes routes that use it
    if [[ -n ${ENDPOINT_IP:-} ]]; then
        ip route del "$ENDPOINT_IP/32" 2> /dev/null || true
    fi
}

pia_last_handshake() {
    wg show "$PIA_IFACE" latest-handshakes 2> /dev/null | awk 'NR == 1 { print $2 + 0; found = 1 } END { if (!found) print 0 }'
}

pia_wait_handshake() {
    local i hs
    for ((i = 0; i < ${1:-20}; i++)); do
        hs=$(pia_last_handshake)
        ((hs > 0)) && return 0
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------
# PIA API: token, server list, region selection, WireGuard registration
# ---------------------------------------------------------------------------
pia_get_token() {
    local out code body
    out=$(printf 'form-string = "username=%s"\nform-string = "password=%s"\n' \
        "$(cfg_escape "$PIA_USERNAME")" "$(cfg_escape "$PIA_PASSWORD")" |
        curl -sS --max-time 20 --config - -w '\n%{http_code}' "$PIA_TOKEN_URL") || {
        warn "could not reach the PIA login API"
        return 1
    }
    code=${out##*$'\n'}
    body=${out%$'\n'*}
    TOKEN=$(jq -r '.token // empty' <<< "$body" 2> /dev/null) || TOKEN=
    if [[ -z $TOKEN ]]; then
        if [[ $code == 4* && $code != 429 ]]; then
            die "PIA rejected the credentials (HTTP $code); check PIA_USERNAME / PIA_PASSWORD"
        fi
        warn "login failed (HTTP $code)"
        return 1
    fi
    debug "obtained API token"
}

pia_fetch_serverlist() {
    local raw
    raw=$(curl -fsS --max-time 30 --retry 2 "$PIA_SERVERLIST_URL") || {
        warn "could not download the PIA server list"
        return 1
    }
    # The response is JSON on the first line followed by a signature.
    raw=${raw%%$'\n'*}
    if ! jq -e '.regions | length > 0' <<< "$raw" > /dev/null 2>&1; then
        warn "server list response is not valid"
        return 1
    fi
    printf '%s' "$raw" > "$PIA_RUN_DIR/serverlist.json"
}

# Probe every candidate in parallel and print the row with the lowest TCP connect time.
pia_fastest_row() {
    local tmp i=0 row meta best
    local -a pids=()
    tmp=$(mktemp -d)
    for row in "$@"; do
        meta=$(cut -f3 <<< "$row")
        (
            t=$(curl -o /dev/null -s --connect-timeout 2 -m 3 -w '%{time_connect}' "http://$meta:443" 2> /dev/null) || true
            printf '%s\t%s\n' "${t:-0}" "$row" > "$tmp/$i"
        ) &
        pids+=("$!")
        i=$((i + 1))
    done
    wait "${pids[@]}" 2> /dev/null || true
    best=$(cat "$tmp"/* 2> /dev/null | awk -F'\t' '$1 + 0 > 0' | sort -n | sed -n '1p')
    rm -rf "$tmp"
    if [[ -z $best ]]; then
        warn "latency probe failed for every region"
        return 1
    fi
    printf '%s\n' "${best#*$'\t'}"
}

pia_select_region() {
    local list=$PIA_RUN_DIR/serverlist.json want=${STICKY_REGION:-$PIA_REGION} need_pf=false
    local row='' r id name
    local -a rows
    is_true "$PIA_PORT_FORWARD" && need_pf=true

    # Fields: id, name, probe ip, wireguard ip, wireguard cn, port_forward
    mapfile -t rows < <(jq -r --argjson pf "$need_pf" '
        .regions[]
        | select((.offline // false) | not)
        | select((.servers.wg // []) | length > 0)
        | select(($pf | not) or (.port_forward // false))
        | [.id, .name, (.servers.meta[0].ip // .servers.wg[0].ip),
           .servers.wg[0].ip, .servers.wg[0].cn, ((.port_forward // false) | tostring)]
        | @tsv' "$list")
    if ((${#rows[@]} == 0)); then
        warn "the server list has no usable region (port forwarding required: $need_pf)"
        return 1
    fi

    if [[ ${want,,} == auto ]]; then
        row=$(pia_fastest_row "${rows[@]}") || return 1
    else
        for r in "${rows[@]}"; do
            IFS=$'\t' read -r id name _ <<< "$r"
            if [[ ${id,,} == "${want,,}" || ${name,,} == "${want,,}" ]]; then
                row=$r
                break
            fi
        done
        if [[ -z $row ]]; then
            if jq -e --arg w "${want,,}" '.regions[] | select((.id | ascii_downcase) == $w or (.name | ascii_downcase) == $w)' "$list" > /dev/null; then
                warn "region '$want' is offline, has no WireGuard server, or lacks port forwarding (PIA_PORT_FORWARD=$PIA_PORT_FORWARD)"
                return 1
            fi
            die "unknown region '$want'. Available ids: $(jq -r '[.regions[].id] | sort | join(", ")' "$list")"
        fi
    fi

    IFS=$'\t' read -r REGION_ID REGION_NAME _ WG_IP WG_CN _ <<< "$row"
    log "region: $REGION_NAME ($REGION_ID), server $WG_IP"
}

# Register an ephemeral key with the selected server.
pia_wg_register() {
    local pub resp
    PRIV_KEY=$(wg genkey) || return 1
    pub=$(wg pubkey <<< "$PRIV_KEY") || return 1
    resp=$(printf 'get\ndata-urlencode = "pt=%s"\ndata-urlencode = "pubkey=%s"\n' \
        "$(cfg_escape "$TOKEN")" "$pub" |
        curl -fsS --max-time 20 --connect-to "$WG_CN::$WG_IP:" --cacert "$PIA_CA_CERT" \
            --config - "https://$WG_CN:1337/addKey") || {
        warn "addKey request to $WG_IP failed"
        return 1
    }
    if ! jq -e '.status == "OK"' <<< "$resp" > /dev/null 2>&1; then
        warn "addKey rejected: $(jq -r '.message // .status // "unknown error"' <<< "$resp" 2> /dev/null)"
        return 1
    fi
    read -r PEER_IP SERVER_KEY SERVER_PORT SERVER_VIP DNS_IP < <(
        jq -r '[.peer_ip, .server_key, .server_port, .server_vip, .dns_servers[0]] | map(tostring) | join(" ")' <<< "$resp")
    [[ -n ${PEER_IP:-} && -n ${SERVER_KEY:-} && -n ${SERVER_PORT:-} ]] || { warn "incomplete addKey response"; return 1; }
}

pia_wg_up() {
    local net
    pia_wg_down
    ENDPOINT_IP=$WG_IP
    killswitch_endpoint "$WG_IP" "$SERVER_PORT" || return 1
    ip link add "$PIA_IFACE" type wireguard 2> /dev/null || {
        warn "cannot create a WireGuard interface (needs --cap-add NET_ADMIN and WireGuard in the host kernel)"
        return 1
    }
    if ! {
        wg set "$PIA_IFACE" private-key /dev/stdin peer "$SERVER_KEY" endpoint "$WG_IP:$SERVER_PORT" \
            allowed-ips 0.0.0.0/0 persistent-keepalive 25 <<< "$PRIV_KEY" &&
            ip -4 address add "$PEER_IP/32" dev "$PIA_IFACE" &&
            ip link set "$PIA_IFACE" mtu "$PIA_MTU" up &&
            ip route replace "$WG_IP/32" "${GWARGS[@]}"
    }; then
        warn "failed to configure the WireGuard interface"
        pia_wg_down
        return 1
    fi
    for net in ${LOCAL_NETWORKS//,/ }; do
        ip route replace "$net" "${GWARGS[@]}" || warn "could not route local network $net"
    done
    # Two /1 routes override the default route without removing it, so the
    # original route returns automatically if the interface goes away.
    if ! { ip route add 0.0.0.0/1 dev "$PIA_IFACE" && ip route add 128.0.0.0/1 dev "$PIA_IFACE"; }; then
        warn "failed to install tunnel routes"
        pia_wg_down
        return 1
    fi
}

pia_write_state() {
    {
        printf 'region_id=%s\nregion_name=%s\nserver_ip=%s\npeer_ip=%s\nconnected_at=%s\n' \
            "$REGION_ID" "$REGION_NAME" "$WG_IP" "$PEER_IP" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$PIA_RUN_DIR/status"
}

# Run one full connect attempt. Returns non-zero if the caller should retry.
pia_connect() {
    pia_restore_dns
    pia_get_token || return 1
    pia_fetch_serverlist || return 1
    pia_select_region || return 1
    pia_wg_register || return 1
    pia_wg_up || return 1
    if ! pia_wait_handshake 20; then
        warn "no WireGuard handshake with $WG_IP"
        pia_wg_down
        return 1
    fi
    if is_true "$PIA_DNS"; then
        pia_set_dns "$DNS_IP"
    fi
    pia_write_state
    log "connected to $REGION_NAME (peer address $PEER_IP)"
    if is_true "$PIA_PORT_FORWARD"; then
        pf_acquire || { pia_wg_down; return 1; }
    fi
    STICKY_REGION=$REGION_ID
}

# Retry pia_connect with exponential backoff.
pia_connect_with_retry() {
    local attempt delay=5
    for ((attempt = 1; attempt <= PIA_CONNECT_RETRIES; attempt++)); do
        if pia_connect; then
            return 0
        fi
        warn "connect attempt $attempt/$PIA_CONNECT_RETRIES failed"
        if ((attempt < PIA_CONNECT_RETRIES)); then
            sleep "$delay"
            delay=$((delay * 2 > 60 ? 60 : delay * 2))
        fi
    done
    # Fall back to the configured region selection on the next full attempt.
    STICKY_REGION=
    return 1
}

# ---------------------------------------------------------------------------
# Port forwarding
# ---------------------------------------------------------------------------
PF_PAYLOAD=
PF_SIGNATURE=
PF_PORT=

pf_curl() {   # pf_curl ENDPOINT KEY=VALUE...
    local endpoint=$1 cfg=get kv
    shift
    for kv in "$@"; do
        cfg+=$'\n'"data-urlencode = \"$(cfg_escape "$kv")\""
    done
    printf '%s\n' "$cfg" |
        curl -fsS --max-time 10 --connect-to "$WG_CN::$SERVER_VIP:" --cacert "$PIA_CA_CERT" \
            --config - "https://$WG_CN:19999/$endpoint"
}

pf_get_signature() {
    local resp
    resp=$(pf_curl getSignature "token=$TOKEN") || { warn "getSignature request failed"; return 1; }
    if ! jq -e '.status == "OK"' <<< "$resp" > /dev/null 2>&1; then
        warn "getSignature rejected: $(jq -r '.message // .status // "unknown"' <<< "$resp" 2> /dev/null)"
        return 1
    fi
    PF_PAYLOAD=$(jq -r '.payload' <<< "$resp")
    PF_SIGNATURE=$(jq -r '.signature' <<< "$resp")
    PF_PORT=$(base64 -d <<< "$PF_PAYLOAD" 2> /dev/null | jq -r '.port')
    [[ $PF_PORT =~ ^[0-9]+$ ]] || { warn "could not decode the forwarded port"; return 1; }
    (
        umask 077
        mkdir -p "$PIA_STATE_DIR"
        printf '%s' "$resp" > "$PIA_STATE_DIR/pf.json.tmp" && mv "$PIA_STATE_DIR/pf.json.tmp" "$PIA_STATE_DIR/pf.json"
    ) 2> /dev/null || warn "could not cache the port-forward signature in $PIA_STATE_DIR"
}

pf_load_cache() {
    local f=$PIA_STATE_DIR/pf.json
    [[ -r $f ]] || return 1
    PF_PAYLOAD=$(jq -r '.payload // empty' "$f" 2> /dev/null) || return 1
    PF_SIGNATURE=$(jq -r '.signature // empty' "$f" 2> /dev/null) || return 1
    [[ -n $PF_PAYLOAD && -n $PF_SIGNATURE ]] || return 1
    PF_PORT=$(base64 -d <<< "$PF_PAYLOAD" 2> /dev/null | jq -r '.port' 2> /dev/null) || return 1
    [[ $PF_PORT =~ ^[0-9]+$ ]]
}

pf_bind() {
    local resp
    resp=$(pf_curl bindPort "payload=$PF_PAYLOAD" "signature=$PF_SIGNATURE") || return 1
    jq -e '.status == "OK"' <<< "$resp" > /dev/null 2>&1
}

# Publish the port atomically and notify the app if it changed.
pf_publish() {
    local old=
    [[ -f $PIA_RUN_DIR/vpn_port ]] && old=$(<"$PIA_RUN_DIR/vpn_port")
    printf '%s\n' "$1" > "$PIA_RUN_DIR/vpn_port.tmp" && mv "$PIA_RUN_DIR/vpn_port.tmp" "$PIA_RUN_DIR/vpn_port"
    if [[ -n $old && $old != "$1" && -f $PIA_RUN_DIR/app_started ]]; then
        log "forwarded port changed: $old -> $1"
        pf_run_hook "$1"
    fi
}

pf_run_hook() {
    [[ -x /opt/scripts/port-changed.sh ]] || return 0
    VPN_PORT=$1 timeout 30 "${APP_PREFIX[@]}" /opt/scripts/port-changed.sh "$1" ||
        warn "port-changed.sh exited with an error"
}

# Reuse the cached signature (keeps the same port across restarts) or get a new one.
pf_acquire() {
    if pf_load_cache && pf_bind; then
        debug "re-bound cached forwarded port $PF_PORT"
    else
        pf_get_signature || return 1
        pf_bind || { warn "bindPort failed"; return 1; }
    fi
    pf_publish "$PF_PORT"
    log "forwarded port: $PF_PORT"
}

# ---------------------------------------------------------------------------
# Supervisor: keeps the tunnel and the forwarded port alive
# ---------------------------------------------------------------------------
pia_supervisor() {
    local now hs next_pf pf_fails=0
    next_pf=$(($(date +%s) + PIA_PF_INTERVAL))
    while sleep "$PIA_CHECK_INTERVAL"; do
        now=$(date +%s)
        hs=$(pia_last_handshake)
        if ((hs == 0 || now - hs > PIA_HANDSHAKE_TIMEOUT)); then
            warn "WireGuard handshake is stale; reconnecting"
            pia_wg_down
            pia_connect_with_retry || die "could not re-establish the VPN after $PIA_CONNECT_RETRIES attempts"
            next_pf=$(($(date +%s) + PIA_PF_INTERVAL))
            pf_fails=0
            continue
        fi
        if is_true "$PIA_PORT_FORWARD" && ((now >= next_pf)); then
            if pf_bind || { pf_get_signature && pf_bind; }; then
                pf_publish "$PF_PORT"
                debug "port forward refreshed"
                next_pf=$((now + PIA_PF_INTERVAL))
                pf_fails=0
            else
                pf_fails=$((pf_fails + 1))
                warn "port-forward refresh failed ($pf_fails/3)"
                if ((pf_fails >= 3)); then
                    pia_wg_down   # the next iteration sees a dead tunnel and reconnects
                    pf_fails=0
                fi
                next_pf=$((now + 30))
            fi
        fi
    done
}
