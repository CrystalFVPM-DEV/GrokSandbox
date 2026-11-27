#!/bin/bash
# Pterodactyl-compatible entrypoint for AeroHost Mumble Premium.
# Wings passes the egg startup command in $STARTUP and does not run it itself.
set -euo pipefail

# mumble-server refuses to run as root. Wings runs as an unprivileged UID
# (not necessarily the image's "container" user). Only drop privileges when
# we are actually root.
if [ "$(id -u)" = "0" ]; then
    mkdir -p /home/container
    # Do not recursively chown a Wings volume as root in production; this path
    # is only for docker run as root during local tests.
    chown -R container:container /home/container 2>/dev/null || true
    exec runuser -u container --preserve-environment -- /entrypoint.sh
fi

mkdir -p /home/container
cd /home/container || exit 1

export HOME=/home/container
export USER="${USER:-container}"
export TZ="${TZ:-UTC}"
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/opt/bragi/venv/bin:${PATH}"
export TMPDIR="${TMPDIR:-/home/container/tmp}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/home/container/.cache}"
export PYTHONUNBUFFERED=1

if INTERNAL_IP=$(ip route get 1 2>/dev/null | awk '{print $(NF-2); exit}'); then
    export INTERNAL_IP
fi

STARTUP="${STARTUP:-/opt/aerohost/start-premium.sh}"
# Support Pterodactyl {{VAR}} placeholders in the startup command.
PARSED=$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')
# Expand variables, then exec through bash so the wrapper stays PID 1's child
# and can supervise murmur + Bragi.
MODIFIED_STARTUP=$(eval echo "${PARSED}")
echo ":/home/container$ ${MODIFIED_STARTUP}"
exec /bin/bash -c "${MODIFIED_STARTUP}"
