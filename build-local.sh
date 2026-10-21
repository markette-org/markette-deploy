#!/bin/sh
# Builds the server and web images from local checkouts, one at a time, then (re)starts the stack.
#
# Prefer this to `docker compose -f docker-compose.build.yml up --build` on a shared host: that builds
# the same server image once per service (migrate, api, worker, beat, mcp) in parallel, and Docker 24's
# buildkit can crash the whole daemon on concurrent builds ("concurrent map read and map write" in
# walkProvenance), restarting every container on the machine.
set -eu
cd "$(dirname "$0")"
[ -f .env ] && . ./.env
TAG="${MARKETTE_VERSION:-latest}"
# Provenance attestations are where the crash happens; local images do not need them.
export BUILDX_NO_DEFAULT_ATTESTATIONS=1
docker build -t "ghcr.io/markette-org/markette-server:$TAG" "${SERVER_SRC:-../markette-server}"
docker build -t "ghcr.io/markette-org/markette-web:$TAG" "${WEB_SRC:-../markette-web}"
case ",${COMPOSE_PROFILES:-}," in
  *,uploader,*)
    docker build -f "${SERVER_SRC:-../markette-server}/Dockerfile.uploader" \
      --build-arg BASE="ghcr.io/markette-org/markette-server:$TAG" \
      -t "ghcr.io/markette-org/markette-uploader:$TAG" "${SERVER_SRC:-../markette-server}"
    ;;
esac
docker compose up -d --no-build
