#!/bin/bash

set -eu

SCRIPT_DIR=$(dirname "$0")
_PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
PROJECT_ROOT=$(readlink -f "$_PROJECT_ROOT")

MODE=production

while getopts m: OPT
do
  case $OPT in
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

# prompt yes or no for confirmation if not forced
read -p "This will recreate the Elasticsearch index. Do you want to continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborting."
  exit 0
fi

docker compose -f "$PROJECT_ROOT/$CONFIG" exec -T "$SERVICE" /init.sh -f
