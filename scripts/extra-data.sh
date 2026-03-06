#!/bin/bash

SCRIPT_DIR=$(dirname $0)
PROJECT_DIR="$SCRIPT_DIR/.."
cd $PROJECT_DIR || exit 1

# default vars.
MODE=prod

usage () {
  echo "Usage: $0 [ -d ]"
  echo "  -d: execute this script for debug."
  echo "  restore extra data from the SQLite database to the Elasticsearch."
  echo "  RECOMMENDED: this script should be executed after upload.sh for uploading json data to Elasticsearch."
  echo
  echo "for development, EXTRA_DATA_DIR, SQLITE_NAME, ES_USER, ES_PASSWORD and ES_INDEX must be defined in .env file"
  echo "for production, these variables are imported in docker-compose.yml."
  exit 1
}

while getopts "d" opt; do
  case $opt in
    d)
      MODE=dev
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [ "$MODE" = "prod" ]; then
  docker compose -f $PROJECT_DIR/docker-compose.yml \
    run --rm -i panther \
      restore-metadata
elif [ "$MODE" = "dev" ]; then
  source $PROJECT_DIR/.env
  export ES_URL ES_API_KEY ES_USER ES_PASSWORD ES_INDEX EXTRA_DATA_DIR SQLITE_NAME
  uv run $PROJECT_DIR/panther/src/panther/main.py \
      restore-metadata --sqlite-db $EXTRA_DATA_DIR/$SQLITE_NAME
else
  usage
fi
