#!/bin/bash
# Start mumble-server, then Bragi connected to 127.0.0.1 on the allocation port.
set -euo pipefail

cd /home/container
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/opt/bragi/venv/bin:${PATH}"

MURMUR_BIN="$(command -v mumble-server || command -v murmurd || true)"
if [ -z "${MURMUR_BIN}" ]; then
    echo "ERROR: mumble-server is not installed in this image."
    exit 1
fi
if [ ! -f /opt/bragi/bragi.py ]; then
    echo "ERROR: Bragi is not installed in this image at /opt/bragi."
    exit 1
fi

mkdir -p /home/container/music /home/container/tmp

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
    "${MURMUR_BIN}" -ini /home/container/murmur.ini -supw "${SUPERUSER_PASSWORD}" \
        >/tmp/murmur-supw.log 2>&1 || true
    # -supw is expected to set the password and exit; do not print the log in case
    # a misconfigured build ever echoed the secret.
    if grep -qiE 'password set|SuperUser' /tmp/murmur-supw.log 2>/dev/null; then
        echo "SuperUser password has been applied."
    else
        echo "WARNING: could not confirm SuperUser password was set. Check mumble-server -supw support."
    fi
    rm -f /tmp/murmur-supw.log
else
    echo "WARNING: SUPERUSER_PASSWORD is empty; SuperUser password was not changed."
fi

PORT="${SERVER_PORT:-64738}"
: > /home/container/murmur.log || true

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
    # Fallback if the log wording changes: port is open on loopback.
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

echo "mumble-server is up (pid ${MURMUR_PID}). Starting Bragi music bot on 127.0.0.1:${PORT}..."

RESTART_BOT=1
while [ "${RESTART_BOT}" = 1 ]; do
    if ! kill -0 "${MURMUR_PID}" 2>/dev/null; then
        echo "ERROR: mumble-server exited. Last log lines:"
        tail -n 40 /home/container/murmur.log || true
        exit 1
    fi
    /opt/bragi/venv/bin/python /opt/bragi/bragi.py --config /home/container/configuration.ini \
        >> /home/container/bragi.log 2>&1 &
    BOT_PID=$!
    echo "Bragi started (pid ${BOT_PID})."
    # Wait for either process; if the bot exits, restart it unless we are shutting down.
    while kill -0 "${BOT_PID}" 2>/dev/null; do
        if ! kill -0 "${MURMUR_PID}" 2>/dev/null; then
            echo "ERROR: mumble-server exited while the bot was running."
            kill -TERM "${BOT_PID}" 2>/dev/null || true
            tail -n 40 /home/container/murmur.log || true
            exit 1
        fi
        sleep 2
    done
    wait "${BOT_PID}" || true
    if [ "${RESTART_BOT}" = 1 ]; then
        echo "Bragi exited; restarting in 5 seconds..."
        sleep 5
    fi
done
