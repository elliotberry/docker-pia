# Docker Private Internet Access Image

## About the image

A small [Private Internet Access](https://www.privateinternetaccess.com) (PIA) container, intended as a base for other images. It connects to PIA over **WireGuard**, keeps the connection healthy, optionally keeps a forwarded port alive, and then starts your application inside the tunnel.

It is built on PIA's documented [manual-connections](https://github.com/pia-foss/manual-connections) protocol on Alpine Linux, so it does not contain the PIA desktop client. The image only ships `wg`, `iptables`, `curl`, `jq` and a few small tools.

Features:

* WireGuard only, using the host kernel's WireGuard support.
* Kill switch (iptables): nothing leaves the container outside the tunnel, and IPv6 is blocked.
* Automatic reconnect when the tunnel goes stale, with exponential backoff.
* Port forwarding with automatic refresh. The port is kept across restarts and exposed as `VPN_PORT` and in `/run/pia/vpn_port`.
* Credentials from environment variables or Docker/Kubernetes secrets (`*_FILE`). They are never written to disk and are removed from the application's environment.
* Clean shutdown (`tini` plus signal handling) and a health check based on the WireGuard handshake and real traffic through the tunnel.
* Three scripts you can override to run your own application.

This documentation format is inspired by the great people over at linuxserver.io.

## Requirements

* The Docker host kernel must support WireGuard (Linux 5.6+, or an older kernel with the WireGuard module). On Docker Desktop for macOS or Windows this depends on the Docker VM's kernel.
* The container needs `NET_ADMIN`. No `/dev/net/tun` device and no `sysctl` settings are needed.
* Do not use `network_mode: host`. The image changes the container's routes and firewall rules.
* A PIA subscription.

## Usage

### docker compose

See [docker-compose.yml](docker-compose.yml) for a complete example using Docker secrets:

```yaml
services:
  docker-pia:
    image: wiorca/docker-pia
    environment:
      PUID: 1000
      PGID: 1000
      TZ: America/New_York
      PIA_USERNAME_FILE: /run/secrets/pia_username
      PIA_PASSWORD_FILE: /run/secrets/pia_password
      PIA_REGION: auto
    volumes:
      - ./config:/config
    secrets: [pia_username, pia_password]
    cap_add: [NET_ADMIN]
    restart: unless-stopped

secrets:
  pia_username:
    file: ./secrets/pia_username
  pia_password:
    file: ./secrets/pia_password
```

### docker

```
docker run -d \
  --name=docker-pia \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=America/New_York \
  -e PIA_USERNAME=username \
  -e PIA_PASSWORD=password \
  -e PIA_REGION=auto \
  -v /location/on/host:/config \
  --cap-add NET_ADMIN \
  --restart unless-stopped \
  wiorca/docker-pia
```

Passing `PIA_PASSWORD` with `-e` is visible in `docker inspect`. Prefer `PIA_PASSWORD_FILE` with a secret or a mounted file.

### Sharing the VPN with other containers

Run other containers with `network_mode: "service:docker-pia"` (compose) or `--network container:docker-pia` so they share the `docker-pia` network namespace. Their traffic then goes through the tunnel and is covered by the kill switch, with no changes to the app's image.

Example: route [qBittorrent](https://docs.linuxserver.io/images/docker-qbittorrent/) through PIA with compose, including a forwarded port:

```yaml
services:
  docker-pia:
    image: wiorca/docker-pia
    environment:
      PUID: 1000
      PGID: 1000
      TZ: America/New_York
      PIA_USERNAME_FILE: /run/secrets/pia_username
      PIA_PASSWORD_FILE: /run/secrets/pia_password
      PIA_REGION: auto
      PIA_PORT_FORWARD: "true"
      LOCAL_NETWORKS: 192.168.1.0/24   # lets your LAN reach the web UI
    ports:
      - "8080:8080"                    # the app's ports are published here, not on the app
    volumes:
      - ./pia-config:/config
      - pia-run:/run/pia               # shares the forwarded port with the app (optional)
    secrets: [pia_username, pia_password]
    cap_add: [NET_ADMIN]
    restart: unless-stopped

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent
    network_mode: "service:docker-pia"   # use docker-pia's network
    depends_on:
      docker-pia:
        condition: service_healthy       # wait until the VPN is up
        restart: true                    # restart this app if docker-pia is recreated
    environment:
      PUID: 1000
      PGID: 1000
      WEBUI_PORT: 8080
    volumes:
      - ./qbittorrent-config:/config
      - ./downloads:/downloads
      - pia-run:/run/pia:ro            # the forwarded port is in /run/pia/vpn_port
    restart: unless-stopped

volumes:
  pia-run:

secrets:
  pia_username:
    file: ./secrets/pia_username
  pia_password:
    file: ./secrets/pia_password
```

Notes:

* Because `qbittorrent` has no network of its own, **publish its ports on `docker-pia`** (above, `8080:8080`). `ports`, `networks` and `dns` cannot be set on a service that uses `network_mode: service:...`.
* Other containers on the same compose network can reach the app through the `docker-pia` hostname, for example `http://docker-pia:8080`.
* If `docker-pia` is recreated or restarted, containers sharing its network lose it and must be restarted. `depends_on` with `restart: true` (Compose 2.17+) does this for you.
* Inside the shared namespace, DNS comes from PIA by default (`PIA_DNS=true`), so the app cannot resolve other compose service names. Use the `docker-pia` hostname from outside, or set `PIA_DNS=false` (DNS queries then leave the VPN).
* To use the forwarded port, set it in your app. The port is in `/run/pia/vpn_port` (shared through the `pia-run` volume above). When it changes while the app is running, `port-changed.sh` is called inside the `docker-pia` container only, so for another container you need to read the file again or extend the image (see [Extending the image](#extending-the-image)).
* The same works with plain Docker: `docker run --network container:docker-pia ...`.

## Parameters

| Parameter | Examples/Options | Function |
| :----: | --- | --- |
| `PUID` | `1000` | Numeric user ID to run the application as |
| `PGID` | `1000` | Numeric group ID to run the application as |
| `TZ` | `Europe/London` | Timezone |
| `PIA_USERNAME` / `PIA_USERNAME_FILE` | `p1234567` | PIA username, or a file containing it |
| `PIA_PASSWORD` / `PIA_PASSWORD_FILE` | | PIA password, or a file containing it |
| `PIA_REGION` | `auto`, `ca_toronto`, `US East` | Region id or name from PIA's server list. `auto` picks the lowest-latency region. Default `auto` |
| `PIA_PORT_FORWARD` | `true`/`false` | Request a forwarded port. Only regions that support port forwarding are used. Default `false` |
| `PIA_KILLSWITCH` | `true`/`false` | Block all traffic outside the tunnel. Default `true` |
| `PIA_DNS` | `true`/`false` | Use PIA's DNS server inside the container. Set to `false` to keep Docker's DNS, which is needed to resolve other container names, but queries then go outside the VPN. Default `true` |
| `LOCAL_NETWORKS` | `192.168.1.0/24,10.0.0.0/8` | Comma-separated networks that stay reachable outside the tunnel (the container's own subnets always do) |
| `PIA_MTU` | `1420` | MTU of the WireGuard interface |
| `PIA_DEBUG_LOGGING` | `true`/`false` | Extra log output. Secrets are never logged |
| `PIA_HEALTH_URL` | `https://1.1.1.1/cdn-cgi/trace` | URL fetched through the tunnel by the health check |
| `PIA_HANDSHAKE_TIMEOUT` | `180` | Seconds without a WireGuard handshake before the tunnel is considered dead |
| `PIA_CONNECT_RETRIES` | `5` | Connection attempts before the container exits (and your restart policy takes over) |
| `VPN_PORT` | `Inactive` or a number | Set automatically for the application: the forwarded port, or `Inactive` |

`PIA_LOCATION` is accepted as a deprecated alias for `PIA_REGION`.

## Volumes

| Volume | Example | Function |
| :----: | --- | --- |
| `/config` | `/opt/docker/docker-pia` | The home directory of the application user. Root-only state (the cached port-forward signature) is kept in `/config/.pia` |

The ownership of `/config` is corrected to `PUID:PGID` on start only if the top-level directory has the wrong owner.

## Extending the image

Three scripts in `/opt/scripts` are designed to be overwritten (copy them in with `COPY --chmod=0755`):

`/opt/scripts/app-setup.sh`: prepares the environment. Runs as root after the VPN is up and before the app starts. A non-zero exit status stops the container.

`/opt/scripts/app-startup.sh`: starts your application in the foreground. It should never exit. It runs as `docker_user:docker_group` with the UID and GID from `PUID` and `PGID`, with `VPN_PORT` set. When it exits, the container exits with the same status.

`/opt/scripts/app-health-check.sh`: called by the health check after the VPN checks pass. It MUST return 0 if the application is healthy.

Optionally, overwrite `/opt/scripts/port-changed.sh`. It is called as the application user with the new port as `$1` (and in `VPN_PORT`) when the forwarded port changes while the app is running, for example after a reconnect to a different server. The current port is always in `/run/pia/vpn_port` and connection details are in `/run/pia/status`.

Example:

```
FROM wiorca/docker-pia
COPY --chmod=0755 my-app-startup.sh /opt/scripts/app-startup.sh
```

## Security notes

* With the kill switch on, only traffic inside the tunnel is allowed. The bootstrap exceptions (token, server list, key registration and DNS) are limited to `root`, which is only this image's own tooling. If you run the app as root (`PUID=0`) the exceptions also apply to it.
* While the tunnel is reconnecting, the application has no network access.
* `PIA_USERNAME`, `PIA_PASSWORD` and the `*_FILE` variables are removed from the application's environment.

## Migrating from 0.x

Version 1.0 replaces the PIA desktop client with a WireGuard-only implementation:

* **OpenVPN is gone**, and so is `piactl`. `PIA_PROTOCOL` is ignored.
* `PIA_REGION` now works (before, it was documented but never applied). `PIA_LOCATION` is still read as an alias.
* `PIA_PORT_FORWARD` now defaults to `false`.
* `PIA_USERNAME`/`PIA_PASSWORD` no longer have defaults baked into the image.
* The default timezone is `UTC`. It used to be set but had no effect.
* `--dns 8.8.8.8` is no longer needed; PIA's DNS is used by default.
* No `/dev/net/tun` is needed, but the host kernel must support WireGuard.
* `app-setup.sh` failing now stops the container.
* `PIA_DEBUG_LOGGING` only controls this image's own logging.

## Updating containers

### Docker Compose

* Update the image: `docker compose pull`
* Recreate the containers: `docker compose up -d`
* Remove old images: `docker image prune`

### Docker run

* `docker pull wiorca/docker-pia`
* `docker stop docker-pia && docker rm docker-pia`
* Run the same `docker run` command again (your `/config` volume and settings are preserved).

For automatic updates you can use a maintained updater such as [Watchtower](https://github.com/nicholas-fedor/watchtower) (the original `containrrr/watchtower` is archived).

## Building locally

```
git clone https://github.com/wiorca/docker-pia.git
cd docker-pia
docker build --pull -t wiorca/docker-pia:latest .
```

## CI and GitHub Container Registry

`.github/workflows/docker.yml` lints the scripts and Dockerfile, then builds a multi-arch (`linux/amd64`, `linux/arm64`) image with SBOM and provenance attestations.

| Event | Result |
| --- | --- |
| Pull request | Build only, nothing is pushed |
| Push to `main` | Pushes `ghcr.io/<owner>/docker-pia:latest` and `:sha-<short>` |
| Tag `vX.Y.Z` | Pushes `:X.Y.Z`, `:X.Y`, `:X` and `:sha-<short>` |

No secrets need to be configured; the workflow logs in with the built-in `GITHUB_TOKEN`. To release, update `VERSION` and run `git tag vX.Y.Z && git push --tags`. After the first push, open the package on GitHub (Packages → docker-pia → Package settings) to make it public if you want anonymous pulls.

To lint the scripts and the Dockerfile locally:

```
shellcheck scripts/*.sh scripts/lib/pia.sh hooks/build
hadolint Dockerfile
```

### Smoke test

```
mkdir -p secrets config
printf '%s' 'YOUR_PIA_USERNAME' > secrets/pia_username
printf '%s' 'YOUR_PIA_PASSWORD' > secrets/pia_password
docker compose up
# in another terminal:
docker compose exec docker-pia /opt/scripts/health-check.sh
docker compose exec docker-pia curl -s https://ifconfig.me   # should show a PIA address
docker compose exec docker-pia cat /run/pia/status
```
