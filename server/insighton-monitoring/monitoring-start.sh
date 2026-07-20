#!/bin/bash
set -e
cd "$(dirname "$0")"

docker run --rm -v "$(pwd):/data" alpine sh -c "chown root:root /data/filebeat.yml && chmod go-w /data/filebeat.yml"

docker compose up -d