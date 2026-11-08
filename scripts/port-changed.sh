#!/usr/bin/env bash

# Optional hook: called as docker_user when the forwarded port changes while the
# app is running (for example after a reconnect to a different server).
# $1 and $VPN_PORT hold the new port. Overwrite this file in your image to, for
# example, push the new port to your application's API. Keep it short; it is
# stopped after 30 seconds.

echo "[port-changed] forwarded port is now $1"
