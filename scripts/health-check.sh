#!/usr/bin/env bash
#
# Container health: the WireGuard tunnel must be fresh and carry traffic, and the
# application's own check (app-health-check.sh) must pass. Exit 0 when healthy.

set -uo pipefail

# shellcheck source=lib/pia.sh
source /opt/scripts/lib/pia.sh

hs=$(pia_last_handshake)
now=$(date +%s)

if ((hs == 0)); then
    echo "Health BAD: no WireGuard handshake yet"
    exit 1
fi

if ((now - hs > PIA_HANDSHAKE_TIMEOUT)); then
    echo "Health BAD: last handshake $((now - hs))s ago (limit ${PIA_HANDSHAKE_TIMEOUT}s)"
    exit 1
fi

# Bind to the tunnel interface so a leak through eth0 cannot mask a dead tunnel.
# The default URL is an IP address, so this does not depend on DNS.
if ! curl -fsS -o /dev/null --max-time 8 --interface "$PIA_IFACE" "$PIA_HEALTH_URL" 2> /dev/null; then
    echo "Health BAD: no connectivity through $PIA_IFACE"
    exit 1
fi

if ! /opt/scripts/app-health-check.sh; then
    echo "Health BAD: application check failed"
    exit 1
fi

echo "Health OK"
exit 0
