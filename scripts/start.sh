#!/bin/bash

SCRIPT_DIR=$(dirname $0)
PROJECT_DIR="$SCRIPT_DIR/.."
cd $PROJECT_DIR || exit 1

docker compose -f $PROJECT_DIR/docker-compose.yml \
    up -d joker fox es01 nginx
