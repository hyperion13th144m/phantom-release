#!/bin/bash

# generate OpenAPI client code for
# developing project using the OpenAPI.

SCRIPT_DIR=$(dirname "$0")
_PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
PROJECT_ROOT=$(readlink -f "$_PROJECT_ROOT")

# default vars.
case "$1" in
  "crow")
    TARGET=crow
    ;;
  "panther")
    TARGET=panther
    export MONA_URL=http://mona-dev:8000
    ;;
  "mona")
    TARGET=mona
    ;;
  *)
    echo "Usage: $0 [crow|panther|mona]"
    exit 1
    ;;
esac

declare -A SRC_DIR=(
  ["crow"]="$PROJECT_ROOT/services/crow"
  ["panther"]="$PROJECT_ROOT/services/panther"
  ["mona"]="$PROJECT_ROOT/services/mona"
)

OUTPUT_DIR=$(readlink -f $PROJECT_ROOT/api)
echo $OUTPUT_DIR
echo ${SRC_DIR[$TARGET]}
pushd ${SRC_DIR[$TARGET]} > /dev/null
  
echo "Generating OpenAPI schema for $TARGET..."
uv run $PROJECT_ROOT/scripts/build-openapi.py $TARGET $OUTPUT_DIR
popd > /dev/null 


echo "Done generating OpenAPI schema $TARGET."
