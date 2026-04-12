#!/bin/bash

docker compose -f docker-compose.dev.yml run --rm -i queen-dev build-all
