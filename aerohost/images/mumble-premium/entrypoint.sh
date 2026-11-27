#!/bin/bash
# Pterodactyl-compatible entrypoint for AeroHost Mumble Premium.
set -euo pipefail

# mumble-server refuses to run as root. Wings normally starts as an unprivileged
# UID; if someone runs the image as root, drop to the container user.
if [ "$(id -u)" = "0" ]; then
    mkdir -p /home/container
    chown -R container:container /home/container || true
    exec runuser -u container --preserve-environment -- /opt/aerohost/entrypoint.sh
fi

mkdir -p /home/container
cd /home/container

export HOME=/home/container
export USER="${USER:-container}"
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/opt/bragi/venv/bin:${PATH}"

if INTERNAL_IP=$(ip route get 1 2>/dev/null | awk '{print $(NF-2); exit}'); then
    export INTERNAL_IP
fi

STARTUP="${STARTUP:-/opt/aerohost/start-premium.sh}"
# Support Pterodactyl {{VAR}} placeholders in the startup command.
MODIFIED_STARTUP=$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo ":/home/container$ ${MODIFIED_STARTUP}"
eval "exec ${MODIFIED_STARTUP}"
