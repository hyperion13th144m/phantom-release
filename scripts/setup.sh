#!/bin/bash

set -eu

SCRIPT_DIR=$(dirname "$0")
_PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
PROJECT_ROOT=$(readlink -f "$_PROJECT_ROOT")

MODE=${1:-production}

echo "Setting up Elasticsearch mapping"
"$SCRIPT_DIR/es.sh" -m "$MODE"
