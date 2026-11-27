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

PORT="${SERVER_PORT:-64738}"
touch /home/container/murmur.log /home/container/bragi.log
# The egg/config parser may force logfile=/home/container/murmur.log, so murmur
# writes there instead of stdout. Mirror the file to the console so Wings can
# match the done string "Server listening on".
tail -n 0 -F /home/container/murmur.log &
MURMUR_TAIL_PID=$!

echo "Starting mumble-server on port ${PORT}..."
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

# Wait until murmur is listening or the process dies.
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
    if (command -v ss >/dev/null && ss -lntu | grep -q ":${PORT} ") || \
       (command -v netstat >/dev/null && netstat -lntu 2>/dev/null | grep -q ":${PORT} "); then
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

# Re-emit the done string on stdout in case tail -F has not flushed yet, then
# give murmur a moment to finish TLS certificate generation before the bot connects.
grep "Server listening on" /home/container/murmur.log | tail -n 1
sleep 2

echo "mumble-server is up (pid ${MURMUR_PID}). Starting Bragi music bot on 127.0.0.1:${PORT}..."

while true; do
    if ! kill -0 "${MURMUR_PID}" 2>/dev/null; then
        echo "ERROR: mumble-server exited. Last log lines:"
        tail -n 40 /home/container/murmur.log || true
        exit 1
    fi

    echo "Starting Bragi..."
    set +e
    /opt/bragi/venv/bin/python /opt/bragi/bragi.py --config /home/container/configuration.ini \
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
