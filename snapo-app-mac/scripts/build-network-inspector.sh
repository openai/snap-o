#!/bin/sh

set -eu

WEB_DIR="${PROJECT_DIR}/../snapo-network-inspector-web"
WEB_SOURCE="${WEB_DIR}/dist-renderer"
WEB_DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/NetworkInspector"
LEGACY_HELPER="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/Snap-O Network Inspector.app"
STAMP="${DERIVED_FILE_DIR}/snapo-network-inspector.sha256"

if [ -n "${SNAPO_NODE_BIN_DIR:-}" ]; then
  PATH="${SNAPO_NODE_BIN_DIR}:${PATH}"
fi
PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
export PATH

if ! command -v npm >/dev/null 2>&1; then
  echo "error: npm not found. Install Node.js or make npm available to Xcode build scripts." >&2
  exit 1
fi

input_hash=$(
  /usr/bin/find \
    "${WEB_DIR}/src" \
    "${WEB_DIR}/index.html" \
    "${WEB_DIR}/package.json" \
    "${WEB_DIR}/package-lock.json" \
    "${WEB_DIR}/tsconfig.json" \
    "${WEB_DIR}/vite.config.ts" \
    -type f -print0 \
    | /usr/bin/xargs -0 /usr/bin/shasum -a 256 \
    | /usr/bin/shasum -a 256 \
    | /usr/bin/awk '{ print $1 }'
)

if [ -f "${STAMP}" ] && [ -f "${WEB_DEST}/index.html" ]; then
  previous_hash=$(/bin/cat "${STAMP}")
  if [ "${input_hash}" = "${previous_hash}" ]; then
    exit 0
  fi
fi

if [ ! -d "${WEB_DIR}/node_modules" ] \
  || [ ! -f "${WEB_DIR}/node_modules/.package-lock.json" ] \
  || [ "${WEB_DIR}/package-lock.json" -nt "${WEB_DIR}/node_modules/.package-lock.json" ]; then
  (cd "${WEB_DIR}" && npm ci --registry=https://openai.firewall.socket.dev/npm/)
fi

(cd "${WEB_DIR}" && npm run build:frontend)

if [ ! -f "${WEB_SOURCE}/index.html" ]; then
  echo "error: Network Inspector web bundle not found at ${WEB_SOURCE}." >&2
  exit 1
fi

/bin/rm -rf "${WEB_DEST}" "${LEGACY_HELPER}"
/bin/mkdir -p "$(/usr/bin/dirname "${WEB_DEST}")" "$(/usr/bin/dirname "${STAMP}")"
/usr/bin/ditto "${WEB_SOURCE}" "${WEB_DEST}"
/usr/bin/printf '%s' "${input_hash}" > "${STAMP}"
