# syntax=docker/dockerfile:1

# Lean WireGuard-only PIA client, built on PIA's documented manual-connections protocol.
FROM alpine:3.24

ARG BUILD_DATE
ARG VCS_REF
ARG VERSION=1.0.0

LABEL org.opencontainers.image.title="docker-pia" \
      org.opencontainers.image.description="Private Internet Access (WireGuard) container to use as a base for other images" \
      org.opencontainers.image.url="https://github.com/wiorca/docker-pia" \
      org.opencontainers.image.source="https://github.com/wiorca/docker-pia.git" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$VCS_REF \
      org.opencontainers.image.created=$BUILD_DATE

# Runtime packages only: no GUI client, no expect, no net-tools. Versions follow the pinned Alpine release.
# hadolint ignore=DL3018
RUN apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        ip6tables \
        iproute2 \
        iptables \
        iptables-legacy \
        jq \
        su-exec \
        tini \
        tzdata \
        wireguard-tools-wg

# The application home directory and configuration files.
VOLUME [ "/config" ]

# Credentials are intentionally not defaulted here; pass PIA_USERNAME/PIA_PASSWORD
# (or PIA_USERNAME_FILE/PIA_PASSWORD_FILE) at runtime.
ENV TZ=UTC \
    PUID=1000 \
    PGID=1000 \
    PIA_PORT_FORWARD=false \
    PIA_KILLSWITCH=true \
    PIA_DNS=true \
    PIA_DEBUG_LOGGING=false \
    IMAGE_VERSION=$VERSION

# PIA's CA certificate, used to verify the WireGuard and port-forward APIs.
COPY certs/ca.rsa.4096.crt /opt/pia/ca.rsa.4096.crt

# Scripts change most often, so they come last to keep the layers above cached.
COPY --chmod=0755 scripts/ /opt/scripts/

HEALTHCHECK --interval=30s --timeout=15s --start-period=60s --retries=3 \
    CMD [ "/opt/scripts/health-check.sh" ]

ENTRYPOINT [ "/sbin/tini", "--" ]
CMD [ "/opt/scripts/entrypoint.sh" ]
