#!/bin/bash
# Start mumble-server, then Bragi connected to 127.0.0.1 on the allocation port.
# Murmur and Bragi logs are mirrored to the console so Wings can see the
# "Server listening on" done string and any Bragi crash.
set -euo pipefail

cd /home/container
export HOME=/home/container
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/opt/bragi/venv/bin:${PATH}"
export TMPDIR="${TMPDIR:-/home/container/tmp}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/home/container/.cache}"
export PYTHONUNBUFFERED=1

MURMUR_BIN="$(command -v mumble-server || command -v murmurd || true)"
if [ -z "${MURMUR_BIN}" ]; then
    echo "ERROR: mumble-server is not installed in this image."
    exit 1
fi
if [ ! -f /opt/bragi/bragi.py ]; then
    echo "ERROR: Bragi is not installed in this image at /opt/bragi."
    exit 1
fi

mkdir -p /home/container/music /home/container/tmp /home/container/.cache

# Apply panel variables to murmur.ini and configuration.ini (passwords are never echoed).
python3 /opt/aerohost/apply_config.py

# Resolve the allocation port: SERVER_PORT, else murmur.ini (egg parser), never a
# stale 64738 if the ini already has the real port. Bragi always uses 127.0.0.1.
PORT="$(python3 - << 'PY'
import os, re
from pathlib import Path

def valid(value):
    try:
        n = int(str(value).strip())
    except (TypeError, ValueError):
        return ""
    return str(n) if 1 <= n <= 65535 else ""

port = valid(os.environ.get("SERVER_PORT", ""))
if not port:
    ini = Path("/home/container/murmur.ini")
    if ini.is_file():
        for line in ini.read_text(encoding="utf-8", errors="replace").splitlines():
            s = line.strip()
            if s.startswith(";") or s.startswith("#"):
                continue
            m = re.match(r"^port\s*=\s*(\d+)\s*$", s, re.I)
            if m:
                port = valid(m.group(1))
                break
print(port or "64738")
PY
)"

if [ ! -f /home/container/bragi.pem ]; then
    echo "Generating a self-signed certificate for the music bot identity..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /home/container/bragi.pem \
        -out /home/container/bragi.pem \
        -subj "/CN=${BOT_NAME:-AeroHost DJ}" >/dev/null 2>&1
fi

if [ -n "${SUPERUSER_PASSWORD:-}" ]; then
    echo "Setting SuperUser password from the panel variable..."
    SUPW_LOG="/home/container/.murmur-supw.log"
    "${MURMUR_BIN}" -ini /home/container/murmur.ini -supw "${SUPERUSER_PASSWORD}" \
        >"${SUPW_LOG}" 2>&1 || true
    # -supw is expected to set the password and exit; do not print the log in case
    # a misconfigured build ever echoed the secret.
    if grep -qiE 'password set|SuperUser' "${SUPW_LOG}" 2>/dev/null; then
        echo "SuperUser password has been applied."
    else
        echo "WARNING: could not confirm SuperUser password was set. Check mumble-server -supw support."
    fi
    rm -f "${SUPW_LOG}"
else
    echo "WARNING: SUPERUSER_PASSWORD is empty; SuperUser password was not changed."
fi

touch /home/container/murmur.log /home/container/bragi.log
# The egg/config parser may force logfile=/home/container/murmur.log, so murmur
# writes there instead of stdout. Mirror the file to the console so Wings can
# match the done string "Server listening on".
tail -n 0 -F /home/container/murmur.log &
MURMUR_TAIL_PID=$!

echo "Starting mumble-server on 0.0.0.0:${PORT}..."
"${MURMUR_BIN}" -fg -ini /home/container/murmur.ini >> /home/container/murmur.log 2>&1 &
MURMUR_PID=$!

shutdown() {
    echo "Stopping Mumble Premium..."
    if [ -n "${BOT_PID:-}" ]; then
        kill -TERM "${BOT_PID}" 2>/dev/null || true
    fi
    if [ -n "${MURMUR_PID:-}" ]; then
        kill -TERM "${MURMUR_PID}" 2>/dev/null || true
    fi
    if [ -n "${MURMUR_TAIL_PID:-}" ]; then
        kill -TERM "${MURMUR_TAIL_PID}" 2>/dev/null || true
    fi
    wait || true
    exit 0
}
trap shutdown SIGINT SIGTERM

# Wait until murmur's log says it is listening, or the process dies.
ready=0
for i in $(seq 1 45); do
    if ! kill -0 "${MURMUR_PID}" 2>/dev/null; then
        echo "ERROR: mumble-server exited before it started listening. Last log lines:"
        tail -n 40 /home/container/murmur.log || true
        exit 1
    fi
    if grep -q "Server listening on" /home/container/murmur.log 2>/dev/null; then
        ready=1
        break
    fi
    sleep 1
done

if [ "${ready}" -ne 1 ]; then
    echo "ERROR: timed out waiting for mumble-server to listen on port ${PORT}."
    tail -n 40 /home/container/murmur.log || true
    kill -TERM "${MURMUR_PID}" 2>/dev/null || true
    exit 1
fi

# Re-emit the done string on stdout in case tail -F has not flushed yet.
grep "Server listening on" /home/container/murmur.log | tail -n 1

# Prefer the port murmur actually bound, in case it differs from SERVER_PORT.
LISTEN_PORT="$(python3 - << 'PY'
import re
from pathlib import Path
text = Path("/home/container/murmur.log").read_text(encoding="utf-8", errors="replace")
ports = re.findall(r"Server listening on \S+:(\d+)", text)
print(ports[-1] if ports else "")
PY
)"
if [ -n "${LISTEN_PORT}" ] && [ "${LISTEN_PORT}" != "${PORT}" ]; then
    echo "WARNING: murmur is listening on ${LISTEN_PORT}, not ${PORT}. Bragi will use ${LISTEN_PORT}."
    PORT="${LISTEN_PORT}"
fi

# Do not start Bragi until 127.0.0.1:$PORT accepts a TLS handshake. The
# "Server listening on" line can appear before the certificate is ready.
echo "Waiting for murmur to accept TLS on 127.0.0.1:${PORT}..."
python3 - "${PORT}" << 'PY'
import socket, ssl, sys, time

host = "127.0.0.1"
port = int(sys.argv[1])
deadline = time.time() + 30
last = "no attempt"
while time.time() < deadline:
    raw = None
    try:
        raw = socket.create_connection((host, port), 1.0)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        sock = ctx.wrap_socket(raw, server_hostname=host)
        sock.close()
        print(f"Murmur is accepting TLS on {host}:{port}.", flush=True)
        sys.exit(0)
    except Exception as exc:
        last = f"{type(exc).__name__}: {exc}"
        if raw is not None:
            try:
                raw.close()
            except Exception:
                pass
        time.sleep(0.25)
print(f"WARNING: {host}:{port} did not complete a TLS handshake in time ({last}). Starting Bragi anyway...", flush=True)
sys.exit(0)
PY

# Report the host/port Bragi will actually use. Never log the server password.
python3 - "${PORT}" << 'PY'
import os, re, sys
from configparser import ConfigParser
from pathlib import Path

port = sys.argv[1]
cfg_host, cfg_port = "", ""
ini = Path("/home/container/configuration.ini")
if ini.is_file():
    c = ConfigParser(interpolation=None)
    c.read(ini, encoding="utf-8")
    if c.has_section("server"):
        cfg_host = c.get("server", "host", fallback="")
        cfg_port = c.get("server", "port", fallback="")

murmur_port = ""
mp = Path("/home/container/murmur.ini")
if mp.is_file():
    for line in mp.read_text(encoding="utf-8", errors="replace").splitlines():
        s = line.strip()
        if s.startswith(";") or s.startswith("#"):
            continue
        m = re.match(r"^port\s*=\s*(\d+)\s*$", s, re.I)
        if m:
            murmur_port = m.group(1)
            break

server_ip = os.environ.get("SERVER_IP", "") or "unset"
server_port = os.environ.get("SERVER_PORT", "") or "unset"
password_set = "set" if os.environ.get("SERVER_PASSWORD", "").strip() else "empty"
print(
    f"Bragi connecting to 127.0.0.1:{port} "
    f"(configuration.ini host={cfg_host or 'unset'} port={cfg_port or 'unset'}; "
    f"murmur.ini port={murmur_port or 'unset'}; "
    f"SERVER_PORT={server_port}; SERVER_IP={server_ip} is not used as the bot host; "
    f"SERVER_PASSWORD is {password_set}).",
    flush=True,
)
PY

# Force host/port on the CLI so a stale or default configuration.ini cannot
# send the bot to SERVER_IP or port 64738. Password stays in the ini only
# (it would otherwise appear in `ps`). Username is passed quoted.
BRAGI_ARGS=(--config /home/container/configuration.ini --server 127.0.0.1 --port "${PORT}")
if [ -n "${BOT_NAME:-}" ]; then
    BRAGI_ARGS+=(--user "${BOT_NAME}")
fi

echo "mumble-server is up (pid ${MURMUR_PID}). Starting Bragi music bot on 127.0.0.1:${PORT}..."

while true; do
    if ! kill -0 "${MURMUR_PID}" 2>/dev/null; then
        echo "ERROR: mumble-server exited. Last log lines:"
        tail -n 40 /home/container/murmur.log || true
        exit 1
    fi

    echo "Starting Bragi on 127.0.0.1:${PORT}..."
    set +e
    /opt/bragi/venv/bin/python /opt/bragi/bragi.py "${BRAGI_ARGS[@]}" \
        2>&1 | tee -a /home/container/bragi.log
    bot_rc="${PIPESTATUS[0]}"
    set -e

    echo "Bragi exited with code ${bot_rc}. Last log lines:"
    tail -n 40 /home/container/bragi.log || true

    if ! kill -0 "${MURMUR_PID}" 2>/dev/null; then
        echo "ERROR: mumble-server exited after Bragi stopped."
        tail -n 40 /home/container/murmur.log || true
        exit 1
    fi
    echo "Restarting Bragi in 5 seconds..."
    sleep 5
done
