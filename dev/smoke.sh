#!/bin/sh
# Builds the image Atlas would from a bundle and checks that it starts and
# answers, without a database. Run by the workflows for each build.
#
#   dev/smoke.sh dist/osteosort-trim-linux-x86_64.tar.gz
set -eu
cd "$(dirname "$0")/.."
bundle=$1
name=osteosort-smoke
# The server's own output is shown however this ends: when it could not
# start, that is the one line that says why.
trap 'docker logs "$name" 2>&1 || true; docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
docker build --build-arg BUNDLE="$bundle" -t osteosort:smoke .
docker run -d --name "$name" -p 3838:3838 -e DB_NAME=none -e DB_USER=none -e DB_PASS=none osteosort:smoke
for i in $(seq 1 60); do
    curl -fsS http://127.0.0.1:3838/healthz >/dev/null 2>&1 && break
    sleep 1
done
curl -fsS http://127.0.0.1:3838/healthz
curl -fsS http://127.0.0.1:3838/ | grep -q "<title>OsteoSort</title>"
test "$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:3838/api/single)" = 400
test "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3838/api/nope)" = 404
