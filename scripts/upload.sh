#!/bin/bash

SCRIPT_DIR=$(dirname $0)
PROJECT_DIR="$SCRIPT_DIR/.."
cd $PROJECT_DIR || exit 1

MODE=prod

usage () {
  echo "Usage: $0 [ -s ] [ -d ]"
  echo "  -d: execute this script for debug."
  echo "  -s: Skip existing documents if they already exist in the index."
  echo
  echo "for development, ES_USER, ES_PASSWORD and ES_INDEX must be defined in .env file"
  echo "for production, these variables are imported in docker-compose.yml."
  exit 1
}

while getopts "sd" opt; do
  case $opt in
    s)
      SKIP_IF_EXISTS="--use-hash-guard"
      ;;
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
      upload-documents $SKIP_IF_EXISTS --data-root /data_dir
elif [ "$MODE" = "dev" ]; then
  source $PROJECT_DIR/.env
  export ES_URL ES_API_KEY ES_USER ES_PASSWORD ES_INDEX
  uv run $PROJECT_DIR/panther/src/panther/main.py \
      upload-documents $SKIP_IF_EXISTS --data-root $DATA_DIR
else
  usage
fi
