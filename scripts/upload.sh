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
  docker compose -f $PROJECT_DIR/docker-compose.yml \
    run --rm -i ghcr.io/hyperion13th144m/phantom-panther:main \
      upload-documents $SKIP_IF_EXISTS --data-root /data-dir
elif [ "$MODE" = "development" ]; then
  if [ "$BUILD" = "true" ]; then
    docker compose -f $PROJECT_DIR/docker-compose.dev.yml build panther-dev
  fi
  docker compose -f $PROJECT_DIR/docker-compose.dev.yml \
    run --rm -i panther-dev \
      upload-documents $SKIP_IF_EXISTS --data-root /data-dir
else
  usage
fi
