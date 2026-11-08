#!/usr/bin/env bash

# Here is where you run the secure service you want to run. Do not exit. Run in foreground.
# Overwrite this file in your docker image. It is run as docker_user:docker_group (PUID:PGID) with
# VPN_PORT in the environment. The forwarded port is also in /run/pia/vpn_port.

trap : TERM INT; sleep infinity & wait
