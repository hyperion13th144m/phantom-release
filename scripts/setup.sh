#!/bin/bash

SCRIPT_DIR=$(dirname $0)
PROJECT_DIR="$SCRIPT_DIR/.."
cd $PROJECT_DIR || exit 1

# default vars.
MODE=prod
MAPPING="--mapping elasticsearch/document-mapping.json"

usage () {
  echo "Usage: $0 [ -d ]"
  echo "  -d: execute this script for debug."
  echo "  create the Elasticsearch index. WARNING: This will delete all existing data in the index."
  echo
  echo "for development, ES_USER, ES_PASSWORD and ES_INDEX must be defined in .env file"
  echo "for production, these variables are imported in docker-compose.yml."
  exit 1
}

while getopts "hd" opt; do
  case $opt in
    h)
      usage
      exit 0
      ;;
    d)
      MODE=dev
      MAPPING="--mapping $PROJECT_DIR/panther/elasticsearch/document-mapping.json"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

ARGS="create-index --recreate"
if [ "$MODE" = "prod" ]; then
  docker compose -f $PROJECT_DIR/docker-compose.yml \
    run --rm -i panther \
      $ARGS $MAPPING
elif [ "$MODE" = "dev" ]; then
  source $PROJECT_DIR/.env
  export ES_URL ES_API_KEY ES_USER ES_PASSWORD ES_INDEX
  uv run $PROJECT_DIR/panther/src/panther/main.py \
      $ARGS $MAPPING
else
  usage
fi
