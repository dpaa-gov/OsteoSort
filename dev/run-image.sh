#!/bin/sh
# Runs the image as Atlas does: same Dockerfile, DB_* from the environment,
# 1 CPU and 2 GiB. The Julia side is compiled locally into dist/ the first
# time (a few minutes); a release downloads it instead.
#
#   dev/run-image.sh             # http://127.0.0.1:3839/
#   dev/run-image.sh --compile   # compile the Julia side again first
#   dev/run-image.sh stop
set -eu
cd "$(dirname "$0")/.."
name=osteosort-julia
port="${PORT:-3839}"
bundle=dist/osteosort-linux-x86_64.tar.gz

docker rm -f "$name" >/dev/null 2>&1 || true
[ "${1:-}" = stop ] && exit 0

if [ "${1:-}" = --compile ] || [ ! -f "$bundle" ]; then
    rm -rf dist
    docker build -f build/Dockerfile --output type=local,dest=dist .
    tar -czf "$bundle" -C dist osteosort
    rm -rf dist/osteosort
fi
docker build --build-arg BUNDLE="$bundle" -t osteosort:julia .
started=$(date +%s.%N)
docker run -d --name "$name" --network osteosort-dev --env-file .env \
    --cpus 1 --memory 2g -p "127.0.0.1:$port:3838" osteosort:julia >/dev/null
until curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; do
    docker inspect -f '{{.State.Running}}' "$name" | grep -q true || { docker logs "$name"; exit 1; }
    sleep 0.2
done
echo "healthy after $(awk "BEGIN { printf \"%.1f\", $(date +%s.%N) - $started }") s: http://127.0.0.1:$port/"
