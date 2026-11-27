#!/bin/bash
# Start mumble-server from /home/container/murmur.ini, then Bragi on
# 127.0.0.1:$SERVER_PORT. Never fall back to 64738 when SERVER_PORT is set.
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

# Wings injects the allocation port. Do not default to 64738.
if [ -z "${SERVER_PORT:-}" ] || ! [[ "${SERVER_PORT}" =~ ^[0-9]+$ ]] \
    || [ "${SERVER_PORT}" -lt 1 ] || [ "${SERVER_PORT}" -gt 65535 ]; then
    echo "ERROR: SERVER_PORT must be a valid allocation port (got '${SERVER_PORT:-unset}'). Refusing to fall back to 64738."
    exit 1
fi
PORT="${SERVER_PORT}"
MURMUR_INI="/home/container/murmur.ini"

# Apply panel variables to murmur.ini and configuration.ini (passwords are never echoed).
python3 /opt/aerohost/apply_config.py

if [ ! -f "${MURMUR_INI}" ]; then
    echo "ERROR: ${MURMUR_INI} is missing after apply_config."
    exit 1
fi

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
    "${MURMUR_BIN}" -ini "${MURMUR_INI}" -supw "${SUPERUSER_PASSWORD}" \
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

# Only treat listen lines written after this point as the current boot.
# A previous run may have logged "Server listening on 0.0.0.0:64738".
LOG_OFFSET="$(wc -c < /home/container/murmur.log | tr -d ' ')"

echo "Starting mumble-server -fg -ini ${MURMUR_INI} on 0.0.0.0:${PORT}..."
"${MURMUR_BIN}" -fg -ini "${MURMUR_INI}" >> /home/container/murmur.log 2>&1 &
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

# Wait until THIS boot's murmur is listening on $SERVER_PORT, or the process dies.
python3 - "${MURMUR_PID}" "${PORT}" "${LOG_OFFSET}" "${MURMUR_INI}" << 'PY'
import os, re, sys, time
from pathlib import Path

pid = int(sys.argv[1])
port = int(sys.argv[2])
offset = int(sys.argv[3] or 0)
ini_path = sys.argv[4]
log_path = Path("/home/container/murmur.log")


def proc_alive(process_id: int) -> bool:
    try:
        os.kill(process_id, 0)
        return True
    except OSError:
        return False


def new_log_text() -> str:
    data = log_path.read_bytes() if log_path.exists() else b""
    if offset >= len(data):
        return ""
    return data[offset:].decode("utf-8", errors="replace")


def listening_ports(text: str) -> list[str]:
    return re.findall(r"Server listening on \S+:(\d+)", text)


def port_is_listening(p: int) -> bool:
    needle = f":{p:04X}"
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            lines = Path(path).read_text().splitlines()[1:]
        except FileNotFoundError:
            continue
        for line in lines:
            parts = line.split()
            if len(parts) < 4:
                continue
            # 0A = TCP_LISTEN
            if parts[3] == "0A" and parts[1].upper().endswith(needle):
                return True
    return False


ini_ok = False
listen_ok = False
tcp_ok = False
last_listen = ""
deadline = time.time() + 45
while time.time() < deadline:
    if not proc_alive(pid):
        print("ERROR: mumble-server exited before it started listening. Last log lines:", flush=True)
        print(new_log_text() or log_path.read_text(encoding="utf-8", errors="replace")[-4000:], end="", flush=True)
        sys.exit(1)
    text = new_log_text()
    if "Initializing settings from /home/container/murmur.ini" in text:
        ini_ok = True
    ports = listening_ports(text)
    if ports:
        last_listen = ports[-1]
        if last_listen != str(port):
            print(
                f"ERROR: murmur is listening on {last_listen}, not SERVER_PORT={port}. "
                f"It must be started with -ini {ini_path} and that file must have port={port}.",
                flush=True,
            )
            print(text, end="", flush=True)
            sys.exit(1)
        listen_ok = True
    tcp_ok = port_is_listening(port)
    if listen_ok and tcp_ok:
        break
    time.sleep(0.25)

text = new_log_text()
if "Initializing settings from " in text and not ini_ok:
    # Started with a different ini than /home/container/murmur.ini
    src = re.findall(r"Initializing settings from (\S+)", text)
    print(
        "ERROR: mumble-server loaded "
        + (src[-1] if src else "an unexpected ini")
        + f" instead of {ini_path}.",
        flush=True,
    )
    sys.exit(1)
if not listen_ok or not tcp_ok:
    print(
        f"ERROR: mumble-server is not listening on 0.0.0.0:{port} "
        f"(log_listen={'yes' if listen_ok else 'no'}, "
        f"tcp_listen={'yes' if tcp_ok else 'no'}, "
        f"last_listen_line_port={last_listen or 'none'}).",
        flush=True,
    )
    print(text or "(no new murmur.log lines)", flush=True)
    sys.exit(1)

# Re-emit the done string from this boot only.
for line in text.splitlines():
    if "Server listening on" in line:
        last = line
    else:
        last = last if "last" in dir() else ""
matches = [line for line in text.splitlines() if "Server listening on" in line]
if matches:
    print(matches[-1], flush=True)
PY

# Do not start Bragi until 127.0.0.1:$SERVER_PORT accepts a TLS handshake.
# The "Server listening on" line can appear before the certificate is ready.
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
print(
    f"ERROR: {host}:{port} did not complete a TLS handshake in time ({last}).",
    flush=True,
)
sys.exit(1)
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

murmur_ports = []
mp = Path("/home/container/murmur.ini")
if mp.is_file():
    for line in mp.read_text(encoding="utf-8", errors="replace").splitlines():
        s = line.strip()
        if s.startswith(";") or s.startswith("#"):
            continue
        m = re.match(r"^port\s*=\s*(\d+)\s*$", s, re.I)
        if m:
            murmur_ports.append(m.group(1))

server_ip = os.environ.get("SERVER_IP", "") or "unset"
server_port = os.environ.get("SERVER_PORT", "") or "unset"
password_set = "set" if os.environ.get("SERVER_PASSWORD", "").strip() else "empty"
print(
    f"Bragi connecting to 127.0.0.1:{port} "
    f"(configuration.ini host={cfg_host or 'unset'} port={cfg_port or 'unset'}; "
    f"murmur.ini port={','.join(murmur_ports) or 'unset'}; "
    f"SERVER_PORT={server_port}; SERVER_IP={server_ip} is not used as the bot host; "
    f"SERVER_PASSWORD is {password_set}).",
    flush=True,
)
if port != server_port:
    print(f"ERROR: wrapper port {port} does not match SERVER_PORT={server_port}.", flush=True)
    sys.exit(1)
if murmur_ports != [port]:
    print(f"ERROR: murmur.ini ports {murmur_ports!r} do not match SERVER_PORT={port}.", flush=True)
    sys.exit(1)
PY

# Force host/port on the CLI so a stale configuration.ini cannot redirect the bot.
# Password stays in the ini only (it would otherwise appear in `ps`).
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
