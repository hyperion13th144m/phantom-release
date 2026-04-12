#!/bin/bash

set -eu

SCRIPT_DIR=$(dirname "$0")
_PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
PROJECT_ROOT=$(readlink -f "$_PROJECT_ROOT")

docker compose -f "$PROJECT_ROOT/docker-compose.yml" \
    up -d crow mona panther joker fox skull es01 nginx

"$SCRIPT_DIR/setup.sh" production
