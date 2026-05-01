#!/bin/sh

set -eu

MISE_VERSION="v2026.4.24"
MISE_SHA256="eb87df7d5fa2772e98e17b75be0d2b9a7fefccd8647ec0990909cc1e35a33f34"
MISE_BIN="${MISE_INSTALL_PATH:-${HOME}/.local/bin/mise}"
MISE_BIN_DIR="$(dirname "${MISE_BIN}")"
MISE_DOWNLOAD="${RUNNER_TEMP:-/tmp}/mise"

trap 'rm -f "${MISE_DOWNLOAD}"' EXIT

mkdir -p "${MISE_BIN_DIR}"
mkdir -p "$(dirname "${MISE_DOWNLOAD}")"
curl -fsSL \
  "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-macos-arm64" \
  -o "${MISE_DOWNLOAD}"
printf '%s  %s\n' "${MISE_SHA256}" "${MISE_DOWNLOAD}" | shasum -a 256 -c -

install -m 0755 "${MISE_DOWNLOAD}" "${MISE_BIN}"

printf '%s\n' "${MISE_BIN_DIR}" >> "${GITHUB_PATH}"
