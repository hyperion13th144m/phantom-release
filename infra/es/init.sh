#!/bin/bash

set -eu

SCRIPT_DIR=$(dirname "$0")
_PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
PROJECT_ROOT=$(readlink -f "$_PROJECT_ROOT")

declare -A INDEXES=(
  ["documents"]="patent-documents"
  ["images"]="patent-images"
)

declare -A MAPPING_FILES=(
  ["documents"]="/mapping/mapping.json"
  ["images"]="/mapping/image-mapping.json"
)

TARGETS=(
    "documents"
    "images"
)

ES_HOST=localhost
ES_PORT=9200
WAIT_SECONDS=60
FORCE_RECREATE=0

while getopts fw: OPT
do
  case $OPT in
  f) FORCE_RECREATE=1
     ;;
  w) WAIT_SECONDS=$OPTARG
     ;;
  *) exit 1
     ;;
  esac
done

echo "Waiting for Elasticsearch to become ready..."
STARTED_AT=$(date +%s)
while true
do
  if curl -fsS "http://$ES_HOST:$ES_PORT/_cluster/health?wait_for_status=yellow&timeout=1s" >/dev/null 2>&1; then
    break
  fi

  NOW=$(date +%s)
  if [ $((NOW - STARTED_AT)) -ge "$WAIT_SECONDS" ]; then
    echo "Elasticsearch did not become ready within ${WAIT_SECONDS} seconds." >&2
    exit 1
  fi

  sleep 2
done

for TARGET in "${TARGETS[@]}"
do
  INDEX=${INDEXES[$TARGET]}
  MAPPING_FILE=${MAPPING_FILES[$TARGET]}

  if [ "$FORCE_RECREATE" -eq 1 ]; then
    echo "Recreating index with force option: $INDEX"
    curl -fsS -X DELETE "http://$ES_HOST:$ES_PORT/$INDEX" >/dev/null 2>&1 || true
  else
    echo "Index already exists: $INDEX"
    echo "Skipping mapping upload."
    exit 0
  fi

  echo "Creating index with mapping: $INDEX"
  if ! curl -fsS -X PUT "http://$ES_HOST:$ES_PORT/$INDEX" \
    -H 'Content-Type: application/json' \
    -d @"$MAPPING_FILE" >/dev/null 2>&1; then
    echo "Failed to create index with mapping." >&2
    exit 1
  else
    echo "Index created with mapping successfully."
  fi
done  
