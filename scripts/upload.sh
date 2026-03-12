#!/bin/bash

SCRIPT_DIR=$(dirname $0)
PROJECT_DIR="$SCRIPT_DIR/.."
cd $PROJECT_DIR || exit 1

BUILD="false"

usage () {
  echo "Usage: $0 [ -s ] [ -b ]"
  echo "  -b: Build the Docker image before running the script in development mode."
  echo "  -s: Skip existing documents if they already exist in the index."
  echo
  echo "MODE, DATA_DIR, ES_USER, ES_PASSWORD and ES_INDEX must be defined in .env file"
  exit 1
}

# MODE, DATA_DIR, ES_USER, ES_PASSWORD and ES_INDEX must be defined in .env file.
source $PROJECT_DIR/.env

while getopts "hsb" opt; do
  case $opt in
    h)
      usage
      exit 0
      ;;
    s)
      SKIP_IF_EXISTS="--use-hash-guard"
      ;;
    b)
      BUILD="true"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [ "$MODE" = "production" ]; then
  DOCKER_COMPOSE="-f $PROJECT_DIR/docker-compose.yml"
  CONTAINER_NAME="panther"
elif [ "$MODE" = "development" ]; then
  DOCKER_COMPOSE="-f $PROJECT_DIR/docker-compose.dev.yml"
  CONTAINER_NAME="panther-dev"
  if [ "$BUILD" = "true" ]; then
    docker compose $DOCKER_COMPOSE build $CONTAINER_NAME
  fi
else
  usage
  exit 1
fi

docker compose $DOCKER_COMPOSE \
  run --rm -i $CONTAINER_NAME \
    upload-documents $SKIP_IF_EXISTS --data-root /data-dir
