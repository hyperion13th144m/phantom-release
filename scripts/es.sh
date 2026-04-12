#!/bin/bash

set -eu

SCRIPT_DIR=$(dirname "$0")
_PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
PROJECT_ROOT=$(readlink -f "$_PROJECT_ROOT")

INDEX=patent-documents
ES_HOST=localhost
ES_PORT=9200
MODE=production
WAIT_SECONDS=60
FORCE_RECREATE=0

while getopts fm:e:p:i:w: OPT
do
  case $OPT in
  f) FORCE_RECREATE=1
     ;;
  m) MODE=$OPTARG
     ;;
  e) ES_HOST=$OPTARG
     ;;
  p) ES_PORT=$OPTARG
     ;;
  i) INDEX=$OPTARG
     ;;
  w) WAIT_SECONDS=$OPTARG
     ;;
  *) exit 1
     ;;
  esac
done

shift $((OPTIND - 1)) # オプション部分をスキップ

MAPPING_FILE=${1:-$PROJECT_ROOT/infra/es/generated/mapping.json}

if [ "$MODE" = "production" ]; then
  CONFIG=docker-compose.yml
  SERVICE=es
else
  CONFIG=docker-compose.dev.yml
  SERVICE=es-dev
fi

echo "Waiting for Elasticsearch to become ready..."
STARTED_AT=$(date +%s)
while true
do
  if docker compose -f "$PROJECT_ROOT/$CONFIG" exec -T "$SERVICE" \
    curl -fsS "http://$ES_HOST:$ES_PORT/_cluster/health?wait_for_status=yellow&timeout=1s" >/dev/null 2>&1; then
    break
  fi

  NOW=$(date +%s)
  if [ $((NOW - STARTED_AT)) -ge "$WAIT_SECONDS" ]; then
    echo "Elasticsearch did not become ready within ${WAIT_SECONDS} seconds." >&2
    exit 1
  fi

  sleep 2
done

if docker compose -f "$PROJECT_ROOT/$CONFIG" exec -T "$SERVICE" \
  curl -fsS "http://$ES_HOST:$ES_PORT/$INDEX" >/dev/null 2>&1; then
  if [ "$FORCE_RECREATE" -eq 1 ]; then
    echo "Recreating index with force option: $INDEX"
    docker compose -f "$PROJECT_ROOT/$CONFIG" exec -T "$SERVICE" \
      curl -fsS -X DELETE "http://$ES_HOST:$ES_PORT/$INDEX" >/dev/null 2>&1 || true
  else
  echo "Index already exists: $INDEX"
  echo "Skipping mapping upload."
  exit 0
  fi
fi

echo "Creating index with mapping: $INDEX"
if ! docker compose -f "$PROJECT_ROOT/$CONFIG" cp "$MAPPING_FILE" "$SERVICE:/tmp/mapping.json" >/dev/null 2>&1; then
  echo "Failed to copy mapping file to container." >&2
  exit 1
else
  echo "Mapping file copied to container successfully."
fi

if ! docker compose -f "$PROJECT_ROOT/$CONFIG" exec -T "$SERVICE" \
  curl -fsS -X PUT "http://$ES_HOST:$ES_PORT/$INDEX" \
  -H 'Content-Type: application/json' \
  -d @/tmp/mapping.json >/dev/null 2>&1; then
  echo "Failed to create index with mapping." >&2
  exit 1
else
  echo "Index created with mapping successfully."
fi
