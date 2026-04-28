#!/bin/bash

set -eu

SCRIPT_DIR=$(dirname "$0")
_PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
PROJECT_ROOT=$(readlink -f "$_PROJECT_ROOT")

VIOLET_ENABLE_EMBEDDINGS=${VIOLET_ENABLE_EMBEDDINGS:-0}

if [ "$VIOLET_ENABLE_EMBEDDINGS" -eq 1 ]; then
    echo "Enabling embeddings in Elasticsearch configuration"
    PROFILES=embeddings
else
    echo "Using default Elasticsearch configuration without embeddings"
    PROFILES=normal
fi

docker compose -f "$PROJECT_ROOT/docker-compose.yml" \
    --profile "$PROFILES" up -d 
