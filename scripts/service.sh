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
    *)
        echo "Usage: $0 {start|stop}" >&2
        exit 1
        ;;
esac
