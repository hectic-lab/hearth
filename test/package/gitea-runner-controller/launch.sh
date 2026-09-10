#!/bin/dash
set -eu

GCR_STATE_DIR="$(mktemp -d)"
export GCR_STATE_DIR
export GCR_LOG=error
trap 'rm -rf "$GCR_STATE_DIR"' EXIT INT HUP

dash "$test/run.sh"
