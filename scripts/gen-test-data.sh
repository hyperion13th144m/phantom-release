#!/bin/bash

SCRIPT_DIR="$(dirname $0)"
PROJECT_ROOT="$SCRIPT_DIR/.."
TEST_DATA_DIR="$PROJECT_ROOT/../test-data"
cd $PROJECT_ROOT || exit 1

find $TEST_DATA_DIR -type d -name xml | while read s
do
  o=$(dirname $s)/xml-to-json
  $SCRIPT_DIR/translate-all.sh $s $o
done
