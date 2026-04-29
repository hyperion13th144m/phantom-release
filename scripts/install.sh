#!/bin/bash

set -eu

SCRIPT_DIR=$(dirname "$0")
_PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
PROJECT_ROOT=$(readlink -f "$_PROJECT_ROOT")

echo "Pulling images..."
docker compose -f "$PROJECT_ROOT/docker-compose.yml" \
       pull crow fox joker mona navi panther skull

echo "Building images..."
docker compose -f "$PROJECT_ROOT/docker-compose.yml" \
       build violet es

echo "Creating Directories"
mkdir -p "$PROJECT_ROOT/var/data" \
         "$PROJECT_ROOT/var/extra-data" \
         "$PROJECT_ROOT/var/log/crow/{api,jobs,crawling}" \
         "$PROJECT_ROOT/var/log/fox" \
         "$PROJECT_ROOT/var/log/joker" \
         "$PROJECT_ROOT/var/log/mona" \
         "$PROJECT_ROOT/var/log/navi" \
         "$PROJECT_ROOT/var/log/panther" \
         "$PROJECT_ROOT/var/log/skull" \
         "$PROJECT_ROOT/var/log/violet"

echo "Finished installation. You can start the services with './scripts/service.sh start'"
