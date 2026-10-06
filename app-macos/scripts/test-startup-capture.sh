#!/bin/sh
set -eu

case "${1:-}" in
  ""|--controllers-only|--modes-only|--sessions-only|--connections-only) ;;
  *) echo "Unknown test option: $1" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  echo "Expected at most one test option" >&2
  exit 2
fi

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Keep the existing entry points while running the current owners.
case "${1:-}" in
  --controllers-only|--modes-only)
    exec sh "$APP_DIR/scripts/test-media-lifetime.sh"
    ;;
  --connections-only)
    exec sh "$APP_DIR/scripts/test-preview-input.sh"
    ;;
  --sessions-only)
    sh "$APP_DIR/scripts/test-preview-input.sh"
    exec sh "$APP_DIR/scripts/test-video-stream.sh"
    ;;
  "")
    sh "$APP_DIR/scripts/test-media-lifetime.sh" --windows
    exec sh "$APP_DIR/scripts/test-video-stream.sh"
    ;;
esac
