#!/bin/bash

SCRIPT_DIR=$(dirname $0)
PROJECT_DIR="$SCRIPT_DIR/.."
cd $PROJECT_DIR || exit 1

# default vars.
BUILD="false"

usage () {
  echo "Usage: $0 [ -b ]"
  echo "  -b: Build the Docker image before running the script in development mode."
  echo "  restore extra data from the SQLite database to the Elasticsearch."
  echo "  RECOMMENDED: this script should be executed after upload.sh for uploading json data to Elasticsearch."
  echo
  echo "MODE, EXTRA_DATA_DIR, SQLITE_NAME, ES_USER, ES_PASSWORD and ES_INDEX must be defined in .env file"
  exit 1
}

# MODE, ES_USER, ES_PASSWORD and ES_INDEX must be defined in .env file.
source $PROJECT_DIR/.env

while getopts "hb" opt; do
  case $opt in
    h)
      usage
      exit 0
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
      restore-metadata
elif [ "$MODE" = "development" ]; then
  if [ "$BUILD" = "true" ]; then
    docker compose -f $PROJECT_DIR/docker-compose.dev.yml build panther-dev
  fi
  docker compose -f $PROJECT_DIR/docker-compose.dev.yml \
    run --rm -i panther-dev \
      restore-metadata
else
  usage
fi
