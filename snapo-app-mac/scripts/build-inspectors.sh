#!/bin/sh
set -eu

INSPECTORS_DIR="${PROJECT_DIR}/../inspectors"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Inspectors"
if [ -n "${SNAPO_NODE_BIN_DIR:-}" ]; then PATH="${SNAPO_NODE_BIN_DIR}:${PATH}"; fi
PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
export PATH
if ! command -v npm >/dev/null 2>&1; then
  echo "error: npm not found. Install Node.js or make npm available to Xcode build scripts." >&2
  exit 1
fi
if [ ! -f "${INSPECTORS_DIR}/node_modules/.package-lock.json" ] \
  || [ "${INSPECTORS_DIR}/package-lock.json" -nt "${INSPECTORS_DIR}/node_modules/.package-lock.json" ]; then
  (cd "${INSPECTORS_DIR}" && npm ci --registry=https://openai.firewall.socket.dev/npm/)
fi
(cd "${INSPECTORS_DIR}" && npm run build)
/bin/rm -rf "${DEST}"
/usr/bin/ditto "${INSPECTORS_DIR}/dist" "${DEST}"
