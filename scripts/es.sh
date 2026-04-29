#!/bin/bash

set -eu

SCRIPT_DIR=$(dirname "$0")
_PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
PROJECT_ROOT=$(readlink -f "$_PROJECT_ROOT")

MODE=production
FORCE_RECREATE=

while getopts fm: OPT
do
  case $OPT in
  f) FORCE_RECREATE="-f"
     ;;
  m) MODE=$OPTARG
     ;;
  *) exit 1
     ;;
  esac
done

if [ "$MODE" = "production" ]; then
  CONFIG=docker-compose.yml
  SERVICE=es
else
  CONFIG=docker-compose.dev.yml
  SERVICE=es-dev
fi
docker compose -f "$PROJECT_ROOT/$CONFIG" exec -T "$SERVICE" /init.sh "$FORCE_RECREATE"
