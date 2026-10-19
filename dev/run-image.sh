#!/bin/sh
# Runs the image as Atlas does: same Dockerfile, DB_* from the environment,
# 1 CPU and 2 GiB. The Julia side is compiled locally into dist/ the first
# time (a few minutes); a release downloads it instead.
#
#   dev/run-image.sh             # http://127.0.0.1:3839/
#   dev/run-image.sh --compile   # compile the Julia side again first
#   dev/run-image.sh stop
#
# With --trim, in any position, it is the trimmed build that is compiled and
# run, as Atlas runs it: beside the other and on its own port. It takes some
# twenty minutes to compile where the other takes a few.
#
#   dev/run-image.sh --trim             # http://127.0.0.1:3840/
#   dev/run-image.sh --trim --compile
#   dev/run-image.sh --trim stop
set -eu
cd "$(dirname "$0")/.."
trim=0
compile=0
stop=0
for arg in "$@"; do
    case $arg in
        --trim) trim=1 ;;
        --compile) compile=1 ;;
        stop) stop=1 ;;
        *) echo "usage: dev/run-image.sh [--trim] [--compile | stop]" >&2; exit 1 ;;
    esac
done
if [ $trim = 1 ]; then
    name=osteosort-trim
    port="${PORT:-3840}"
    bundle=dist/osteosort-trim-linux-x86_64.tar.gz
    image=osteosort:trim
else
    name=osteosort-julia
    port="${PORT:-3839}"
    bundle=dist/osteosort-linux-x86_64.tar.gz
    image=osteosort:julia
fi

docker rm -f "$name" >/dev/null 2>&1 || true
[ $stop = 1 ] && exit 0

if [ $compile = 1 ] || [ ! -f "$bundle" ]; then
    # compiled into a folder of its own, so that the other build's bundle is left in dist/
    rm -rf "dist/$name" "$bundle"
    docker build -f build/Dockerfile --build-arg TRIM=$trim --output "type=local,dest=dist/$name" .
    tar -czf "$bundle" -C "dist/$name" osteosort
    rm -rf "dist/$name"
fi
docker build --build-arg BUNDLE="$bundle" -t "$image" .
started=$(date +%s.%N)
docker run -d --name "$name" --network osteosort-dev --env-file .env \
    --cpus 1 --memory 2g -p "127.0.0.1:$port:3838" "$image" >/dev/null
until curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; do
    docker inspect -f '{{.State.Running}}' "$name" | grep -q true || { docker logs "$name"; exit 1; }
    sleep 0.2
done
# Docker's own health column says unhealthy all the same: the image has no
# curl for its HEALTHCHECK, which is there for Atlas to read, not to run.
echo "answering after $(awk "BEGIN { printf \"%.1f\", $(date +%s.%N) - $started }") s: http://127.0.0.1:$port/"
