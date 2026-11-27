#!/bin/bash
# Reproduce a Wings-like install + start, then check murmur/Bragi/yt-dlp.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-aerohost-mumble-premium:fix}"
NAME="mumble-premium-wings-e2e"
PORT="${TEST_PORT:-25566}"
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
# Seed a stale Bragi config (public allocation IP + default murmur port) so
# the start wrapper must overwrite it. Wings sets SERVER_IP to the allocation.
sudo tee "${VOL}/configuration.ini" >/dev/null << STALE
[server]
host = 54.37.59.143
port = 64738
password =
channel =
certificate =
tokens =
STALE

# Reproduce the real-node failure mode:
# 1) leftover port=64738 after port=$SERVER_PORT (murmur uses the last line)
# 2) a previous boot logged "Server listening on 0.0.0.0:64738"
# 3) murmur.sqlite config.port=64738, which overrides murmur.ini
echo "port=64738" | sudo tee -a "${VOL}/murmur.ini" >/dev/null
sudo tee "${VOL}/murmur.log" >/dev/null << 'STALELOG'
<W>2026-01-01 00:00:00.000 1 => Server listening on 0.0.0.0:64738
STALELOG
sudo chown -R "${UIDNO}:${UIDNO}" "${VOL}"
echo "==> Creating murmur.sqlite with a leftover port=64738 override"
${DOCKER} run --rm --user "${UIDNO}:${UIDNO}" \
    -e HOME=/home/container \
    -v "${VOL}:/home/container" \
    -w /home/container \
    --entrypoint /usr/bin/mumble-server \
    "${IMAGE}" -ini /home/container/murmur.ini -supw "E2eLocalOnly8k2m" \
    >/tmp/mumble-premium-supw-seed.log 2>&1 || true
sudo python3 - "${VOL}" << 'SEEDDB'
import sqlite3, sys
from pathlib import Path
db = Path(sys.argv[1]) / "murmur.sqlite"
if not db.exists():
    raise SystemExit("expected murmur.sqlite after mumble-server -supw")
con = sqlite3.connect(str(db))
con.execute("DELETE FROM config WHERE lower(key) IN ('port', 'host')")
con.execute("INSERT INTO config (server_id, key, value) VALUES (1, 'port', '64738')")
con.commit()
print("seeded murmur.sqlite config.port=64738")
con.close()
SEEDDB

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
    -e SERVER_IP=54.37.59.143 \
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
    -p "${PORT}:${PORT}" \
    -p "${PORT}:${PORT}/udp" \
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
if echo "${later}" | grep -q "ConnectionRejectedError"; then
    echo "FAIL: Bragi raised ConnectionRejectedError"
    ${DOCKER} logs "${NAME}" 2>&1 | tail -n 60
    exit 1
fi
if ! echo "${later}" | grep -q "Bragi connecting to 127.0.0.1:${PORT}"; then
    echo "FAIL: console did not log Bragi connecting to 127.0.0.1:${PORT}"
    exit 1
fi
if echo "${later}" | grep -E "Bragi connecting to 54\.37\.59\.143|Bragi music bot on 54\.37\.59\.143"; then
    echo "FAIL: Bragi was directed at SERVER_IP instead of 127.0.0.1"
    exit 1
fi
cfg_host="$(sudo python3 -c "from configparser import ConfigParser; from pathlib import Path; import sys; c=ConfigParser(interpolation=None); c.read(Path(sys.argv[1])/'configuration.ini', encoding='utf-8'); print(c.get('server','host',fallback=''), c.get('server','port',fallback=''))" "${VOL}")"
if [ "${cfg_host}" != "127.0.0.1 ${PORT}" ]; then
    echo "FAIL: configuration.ini was not rewritten to 127.0.0.1:${PORT} (got '${cfg_host}')"
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
if echo "${later}" | grep -q "127.0.0.1:64738"; then
    echo "FAIL: wrapper still targeted 64738 even though SERVER_PORT=${PORT}"
    exit 1
fi
ini_ports="$(sudo python3 -c "import re,sys; from pathlib import Path; ports=[m.group(1) for line in Path(sys.argv[1]).read_text().splitlines() if (m:=__import__('re').match(r'^port\\s*=\\s*(\\d+)\\s*$', line.strip()))]; print(','.join(ports))" "${VOL}/murmur.ini")"
if [ "${ini_ports}" != "${PORT}" ]; then
    echo "FAIL: murmur.ini should have exactly port=${PORT} (got '${ini_ports}')"
    exit 1
fi
if ${DOCKER} exec "${NAME}" sh -c 'ss -lntu | grep -E ":64738[[:space:]]"'; then
    echo "FAIL: murmur is still listening on 64738 inside the container"
    exit 1
fi

echo "==> TLS from the host to 127.0.0.1:${PORT} (outside the container)"
python3 - "${PORT}" << 'OUTTLS'
import socket, ssl, sys
port = int(sys.argv[1])
raw = socket.create_connection(("127.0.0.1", port), 5)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
sock = ctx.wrap_socket(raw, server_hostname="127.0.0.1")
print(f"PASS outside: TLS {sock.version()} handshake to 127.0.0.1:{port}")
sock.close()
OUTTLS

echo
echo "PASS: Wings-like start as uid ${UIDNO}."
echo "  murmur listening line reached stdout."
echo "  murmur bound 0.0.0.0:${PORT}; TLS from the host to 127.0.0.1:${PORT} succeeded."
echo "  Bragi stayed connected to 127.0.0.1:${PORT} with SERVER_IP=54.37.59.143 (no restart loop)."
echo "  yt-dlp: $(tr '\n' ' ' < /tmp/mumble-premium-ytdlp.txt)"
