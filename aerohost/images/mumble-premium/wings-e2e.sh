#!/bin/bash
# Reproduce a Wings-like install + start, then check murmur/Bragi/yt-dlp.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-aerohost-mumble-premium:fix}"
NAME="mumble-premium-wings-e2e"
PORT="${TEST_PORT:-26438}"
UIDNO="${WINGS_UID:-988}"
VOL="${VOL:-/tmp/mumble-premium-wings-e2e}"
DOCKER="${DOCKER:-docker}"
EGG_JSON="${EGG_JSON:-}"

if ! ${DOCKER} info >/dev/null 2>&1; then
    if sudo -n docker info >/dev/null 2>&1; then
        DOCKER="sudo docker"
    else
        echo "Docker is not available."
        exit 1
    fi
fi

if [ -z "${EGG_JSON}" ]; then
    if [ -f "${ROOT}/../../../eggs/voice/egg-mumble-premium.json" ]; then
        EGG_JSON="${ROOT}/../../../eggs/voice/egg-mumble-premium.json"
    elif [ -f /workspace/aerohost/eggs-ready/egg-mumble-premium.json ]; then
        EGG_JSON=/workspace/aerohost/eggs-ready/egg-mumble-premium.json
    fi
fi

echo "==> Building ${IMAGE}"
${DOCKER} build -t "${IMAGE}" "${ROOT}"

echo "==> yt-dlp search (no download)"
${DOCKER} run --rm --entrypoint /opt/bragi/venv/bin/yt-dlp "${IMAGE}" \
    --no-download --no-warnings --print "%(title)s [%(extractor)s]" \
    "ytsearch1:never gonna give you up" | tee /tmp/mumble-premium-ytdlp.txt
if ! grep -qiE "never gonna|rick|youtube" /tmp/mumble-premium-ytdlp.txt; then
    echo "WARNING: yt-dlp search did not return an obvious YouTube title."
fi

echo "==> Install script (alpine) into empty volume ${VOL}"
sudo rm -rf "${VOL}"
mkdir -p "${VOL}"
INSTALL_SH=/tmp/mumble-premium-install.sh
python3 - "${EGG_JSON}" "${INSTALL_SH}" << 'PY'
import json, sys
from pathlib import Path
egg = json.loads(Path(sys.argv[1]).read_text())
Path(sys.argv[2]).write_text(egg["scripts"]["installation"]["script"].replace("\r\n", "\n"))
PY
${DOCKER} pull ghcr.io/pterodactyl/installers:alpine >/dev/null
${DOCKER} run --rm \
    -v "${VOL}:/mnt/server" \
    -v "${INSTALL_SH}:/install.sh:ro" \
    --entrypoint /bin/ash \
    ghcr.io/pterodactyl/installers:alpine \
    /install.sh

# Simulate the egg config parser, then chown as Wings does.
sudo python3 - "${VOL}" "${PORT}" << 'PY'
import re, sys
from pathlib import Path
vol, port = Path(sys.argv[1]), sys.argv[2]
p = vol / "murmur.ini"
replacements = {
    "database": "/home/container/murmur.sqlite",
    "logfile": "/home/container/murmur.log",
    "pidfile": "/home/container/murmur.pid",
    "port": port,
    "host": "0.0.0.0",
    "users": "40",
    "bandwidth": "558000",
    "serverpassword": "",
    "opusthreshold": "0",
}
lines, out, seen = p.read_text().splitlines(), [], set()
for line in lines:
    m = re.match(r"^;?\s*([A-Za-z0-9_]+)\s*=", line)
    if m and m.group(1) in replacements and m.group(1) not in seen:
        out.append(f"{m.group(1)}={replacements[m.group(1)]}")
        seen.add(m.group(1))
    else:
        out.append(line)
for k, v in replacements.items():
    if k not in seen:
        out.append(f"{k}={v}")
p.write_text("\n".join(out) + "\n")
PY
sudo chown -R "${UIDNO}:${UIDNO}" "${VOL}"

${DOCKER} rm -f "${NAME}" >/dev/null 2>&1 || true
cleanup() { ${DOCKER} rm -f "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Starting as uid ${UIDNO} with Wings-like env"
${DOCKER} run -d --name "${NAME}" \
    --user "${UIDNO}:${UIDNO}" \
    -e HOME=/home/container \
    -e USER=container \
    -e SERVER_PORT="${PORT}" \
    -e SERVER_IP=0.0.0.0 \
    -e SERVER_MEMORY=1024 \
    -e STARTUP="/opt/aerohost/start-premium.sh" \
    -e MAX_USERS=40 \
    -e BANDWIDTH=558000 \
    -e SERVER_PASSWORD= \
    -e SUPERUSER_PASSWORD="E2eLocalOnly8k2m" \
    -e BOT_NAME="AeroHost DJ" \
    -e BOT_VOLUME=80 \
    -e BOT_CHANNEL= \
    -v "${VOL}:/home/container" \
    -w /home/container \
    -p "127.0.0.1:${PORT}:${PORT}/tcp" \
    -p "127.0.0.1:${PORT}:${PORT}/udp" \
    "${IMAGE}"

ok_listen=0
ok_bot=0
for i in $(seq 1 45); do
    logs="$(${DOCKER} logs "${NAME}" 2>&1 || true)"
    if echo "${logs}" | grep -q "Server listening on"; then
        ok_listen=1
    fi
    if echo "${logs}" | grep -q "Authenticated"; then
        ok_bot=1
    fi
    if echo "${logs}" | grep -q "Initialization complete"; then
        ok_bot=1
    fi
    if [ "${ok_listen}" = 1 ] && [ "${ok_bot}" = 1 ]; then
        break
    fi
    # Also accept murmur.log Authenticated via volume
    if [ "${ok_bot}" != 1 ] && sudo grep -q "Authenticated" "${VOL}/murmur.log" 2>/dev/null; then
        ok_bot=1
    fi
    sleep 2
done

echo "----- docker logs -----"
${DOCKER} logs "${NAME}" 2>&1 | tail -n 80
echo "----- processes -----"
${DOCKER} exec "${NAME}" ps aux || true

# Stay up briefly: the old bug was an immediate restart loop
sleep 8
later="$(${DOCKER} logs "${NAME}" 2>&1 || true)"
if echo "${later}" | grep -q "Bragi exited"; then
    echo "FAIL: Bragi exited during the stability window"
    ${DOCKER} logs "${NAME}" 2>&1 | tail -n 60
    exit 1
fi

if [ "${ok_listen}" != 1 ]; then
    echo "FAIL: 'Server listening on' never appeared on the container console"
    exit 1
fi
if [ "${ok_bot}" != 1 ]; then
    echo "FAIL: could not confirm Bragi connected to murmur"
    exit 1
fi
if ! ${DOCKER} exec "${NAME}" ps aux | grep -q "bragi.py"; then
    echo "FAIL: bragi.py is not running"
    exit 1
fi

echo
echo "PASS: Wings-like start as uid ${UIDNO}."
echo "  murmur listening line reached stdout."
echo "  Bragi stayed connected (no restart loop)."
echo "  yt-dlp: $(tr '\n' ' ' < /tmp/mumble-premium-ytdlp.txt)"
