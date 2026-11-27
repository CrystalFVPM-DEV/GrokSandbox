#!/bin/bash
# Build the image and verify murmur + Bragi + a yt-dlp search. No registry push.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-aerohost-mumble-premium:test}"
NAME="mumble-premium-local-test"
PORT="${TEST_PORT:-26438}"
DOCKER="${DOCKER:-docker}"

if ! ${DOCKER} info >/dev/null 2>&1; then
    if sudo -n docker info >/dev/null 2>&1; then
        DOCKER="sudo docker"
    else
        echo "Docker is not available."
        exit 1
    fi
fi

echo "==> Building ${IMAGE}"
${DOCKER} build -t "${IMAGE}" "${ROOT}"

echo "==> yt-dlp search (no download)"
${DOCKER} run --rm --entrypoint /opt/bragi/venv/bin/yt-dlp "${IMAGE}" \
    --no-download --no-warnings --print "%(title)s [%(extractor)s]" \
    "ytsearch1:never gonna give you up" | tee /tmp/mumble-premium-ytdlp.txt

if ! grep -qiE "never gonna|rick|youtube" /tmp/mumble-premium-ytdlp.txt; then
    echo "WARNING: yt-dlp search did not return an obvious YouTube title (datacenter block?)."
    cat /tmp/mumble-premium-ytdlp.txt
fi

${DOCKER} rm -f "${NAME}" >/dev/null 2>&1 || true
cleanup() {
    ${DOCKER} rm -f "${NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Starting container on port ${PORT}"
# Throwaway SuperUser password for the local test only; not shipped in the egg.
${DOCKER} run -d --name "${NAME}" \
    -e SERVER_PORT="${PORT}" \
    -e MAX_USERS=10 \
    -e BANDWIDTH=558000 \
    -e SERVER_PASSWORD= \
    -e SUPERUSER_PASSWORD="test-premium-pass" \
    -e BOT_NAME="AeroHost DJ" \
    -e BOT_VOLUME=80 \
    -e BOT_CHANNEL= \
    -e STARTUP="/opt/aerohost/start-premium.sh" \
    -p "127.0.0.1:${PORT}:${PORT}/tcp" \
    -p "127.0.0.1:${PORT}:${PORT}/udp" \
    "${IMAGE}"

echo "==> Waiting for murmur + bot"
ok_murmur=0
ok_bot=0
for i in $(seq 1 60); do
    murmur_log="$(${DOCKER} exec "${NAME}" sh -c 'cat /home/container/murmur.log 2>/dev/null' || true)"
    bragi_log="$(${DOCKER} exec "${NAME}" sh -c 'cat /home/container/bragi.log 2>/dev/null' || true)"
    if echo "${murmur_log}" | grep -q "Server listening on"; then
        ok_murmur=1
    fi
    if echo "${bragi_log}" | grep -qiE "connected|connected to|joined|registered|started|online|AeroHost DJ"; then
        ok_bot=1
    fi
    if [ "${ok_murmur}" = 1 ] && [ "${ok_bot}" = 1 ]; then
        break
    fi
    sleep 2
done

echo "----- docker logs (tail) -----"
${DOCKER} logs --tail 80 "${NAME}" || true
echo "----- murmur.log -----"
${DOCKER} exec "${NAME}" sh -c 'cat /home/container/murmur.log 2>/dev/null || true'
echo "----- bragi.log -----"
${DOCKER} exec "${NAME}" sh -c 'cat /home/container/bragi.log 2>/dev/null || true'
echo "----- processes -----"
${DOCKER} exec "${NAME}" ps aux || true

if [ "${ok_murmur}" != 1 ]; then
    echo "FAIL: murmur did not report 'Server listening on'"
    exit 1
fi

if [ "${ok_bot}" != 1 ]; then
    bragi_log="$(${DOCKER} exec "${NAME}" sh -c 'cat /home/container/bragi.log 2>/dev/null' || true)"
    if echo "${bragi_log}" | grep -qiE "failed to connect|traceback|connection refused|authentication failed"; then
        echo "FAIL: Bragi did not connect"
        exit 1
    fi
    if [ -n "${bragi_log}" ]; then
        echo "Bragi produced a log without an obvious success line; treating as FAIL to be safe."
        exit 1
    fi
    echo "FAIL: could not confirm that Bragi connected to murmur (empty log)"
    exit 1
fi

echo
echo "PASS: murmur is listening, Bragi connected, yt-dlp search ran."
echo "yt-dlp result: $(tr '\n' ' ' < /tmp/mumble-premium-ytdlp.txt)"
