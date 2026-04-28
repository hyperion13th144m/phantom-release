#!/bin/bash

set -eu

SCRIPT_DIR=$(dirname "$0")
_PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
PROJECT_ROOT=$(readlink -f "$_PROJECT_ROOT")

case "$1" in
    start)
        docker compose -f "$PROJECT_ROOT/docker-compose.yml" up -d 
        ;;
    stop)
        docker compose -f "$PROJECT_ROOT/docker-compose.yml" down
        ;;
    pull)
        docker compose -f "$PROJECT_ROOT/docker-compose.yml" \
            pull crow fox joker mona navi panther skull
        ;; 
    *)
        echo "Usage: $0 {start|stop|pull}" >&2
        exit 1
        ;;
esac
