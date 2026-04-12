#!/bin/bash

SCRIPT_DIR=$(dirname $0)
PROJECT_DIR="$SCRIPT_DIR/.."

MODE=${1:-development}

if [ "$MODE" = "production" ]; then
  DOCKER_COMPOSE="-f $PROJECT_DIR/docker-compose.yml"
  CONTAINER_NAME="crow"
elif [ "$MODE" = "development" ]; then
  DOCKER_COMPOSE="-f $PROJECT_DIR/docker-compose.dev.yml"
  CONTAINER_NAME="crow-dev"
else
  echo "Invalid MODE: $MODE. Please set MODE to 'production' or 'development' in .env file."
  exit 1
fi


docker compose $DOCKER_COMPOSE \
  run --rm -i $CONTAINER_NAME -m crow.cli $@
