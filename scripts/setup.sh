#!/bin/bash

SCRIPT_DIR=$(dirname $0)
PROJECT_DIR="$SCRIPT_DIR/.."
cd $PROJECT_DIR || exit 1

BUILD="false"

usage () {
  echo "Usage: $0 [ -b ] [ -h ]"
  echo "  -b: Build the Docker image before running the script in development mode."
  echo "  create the Elasticsearch index. WARNING: This will delete all existing data in the index."
  echo
  echo "MODE, ES_USER, ES_PASSWORD and ES_INDEX must be defined in .env file"
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

ARGS="create-index --recreate --mapping elasticsearch/document-mapping.json"
if [ "$MODE" = "production" ]; then
  docker compose -f $PROJECT_DIR/docker-compose.yml \
    run --rm -i panther $ARGS
elif [ "$MODE" = "development" ]; then
  if [ "$BUILD" = "true" ]; then
    docker compose -f $PROJECT_DIR/docker-compose.dev.yml build panther-dev
  fi
  docker compose -f $PROJECT_DIR/docker-compose.dev.yml \
    run --rm -i panther-dev $ARGS
else
  usage
fi
