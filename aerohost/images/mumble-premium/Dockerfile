# AeroHost Mumble Premium
# mumble-server (murmur) + Bragi music bot in one Pterodactyl-compatible image.
# Publish later as e.g. ghcr.io/crystalfvpm-dev/aerohost-mumble-premium:1.0
# (this Dockerfile is not pushed by the build task).

FROM debian:trixie-slim

ARG BRAGI_VERSION=2026.08.31

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    USER=container \
    HOME=/home/container \
    PATH="/usr/sbin:/usr/bin:/sbin:/bin:/opt/bragi/venv/bin"

RUN apt-get update && apt-get install -y --no-install-recommends \
        mumble-server \
        python3 \
        python3-venv \
        python3-pip \
        python3-magic \
        libopus0 \
        libmagic1t64 \
        ffmpeg \
        ca-certificates \
        curl \
        git \
        openssl \
        iproute2 \
        tini \
        netbase \
        procps \
        util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/bragi /opt/aerohost

# Bragi 2026.08.31 — maintained botamusique fork with yt-dlp, !yplay / !ysearch, English UI.
RUN git clone --depth 1 --branch "${BRAGI_VERSION}" https://git.stormux.org/storm/bragi.git /opt/bragi \
    && python3 -m venv /opt/bragi/venv \
    && /opt/bragi/venv/bin/pip install --no-cache-dir --upgrade pip wheel \
    && /opt/bragi/venv/bin/pip install --no-cache-dir -r /opt/bragi/requirements.txt \
    && /opt/bragi/venv/bin/pip install --no-cache-dir -U yt-dlp \
    && chmod -R a+rX /opt/bragi

COPY murmur.ini.template entrypoint.sh start-premium.sh apply_config.py /opt/aerohost/
RUN chmod 755 /opt/aerohost/entrypoint.sh /opt/aerohost/start-premium.sh /opt/aerohost/apply_config.py \
    && useradd -m -d /home/container -s /bin/bash container \
    && mkdir -p /home/container \
    && chown -R container:container /home/container \
    && git config --system --add safe.directory /opt/bragi \
    && chmod -R a+rX /opt/aerohost

USER container
WORKDIR /home/container

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/aerohost/entrypoint.sh"]
