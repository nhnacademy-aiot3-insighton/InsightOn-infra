#!/bin/bash

set -e

GLOBAL_LOCK="$HOME/deploy-scripts/.insighton-deploy.lock"
INFRA_DIR="$HOME/insighton-infra"

SCRIPT_NAME=$1

if [ -z "$SCRIPT_NAME" ]; then
        echo "usage: $0 <deploy-script-name>"
        exit 1
fi

(
        flock -x 200

        rm -rf "$INFRA_DIR"
        git clone https://github.com/nhnacademy-aiot3-insighton/InsightOn-infra.git "$INFRA_DIR"

        chmod +x "$INFRA_DIR/scripts/$SCRIPT_NAME"
        "$INFRA_DIR/scripts/$SCRIPT_NAME"

) 200>"$GLOBAL_LOCK"