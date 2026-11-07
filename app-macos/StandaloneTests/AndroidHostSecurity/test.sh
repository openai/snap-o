#!/bin/bash
set -euo pipefail
APP_DIR=$(cd "$(dirname "$0")/../.." && pwd)
OUTPUT=$(mktemp -d)
trap 'if [ $? -eq 0 ]; then rm -rf "$OUTPUT"; else printf "Security test files: %s\n" "$OUTPUT"; fi' EXIT
cd "$APP_DIR"
. "$APP_DIR/scripts/test-swift.sh"
swiftc_for_tests -swift-version 6 -parse-as-library \
  AndroidHostService/AndroidHostAuthentication.swift StandaloneTests/AndroidHostSecurity/PolicyTests.swift \
  -o "$OUTPUT/policy-tests"
run_test "$OUTPUT/policy-tests"

CONFIGURATION=${SNAPO_TEST_CONFIGURATION:-Debug}
case "$CONFIGURATION" in
  Debug|Local|Release) ;;
  *) printf 'Unsupported configuration: %s\n' "$CONFIGURATION" >&2; exit 2 ;;
esac
if [ -z "${1:-${SNAPO_DERIVED_DATA:-}}" ]; then
  printf 'Skip XPC integration tests: pass a built helper or set SNAPO_DERIVED_DATA.\n'
  exit 0
fi
SERVICE=${1:-$SNAPO_DERIVED_DATA/Build/Products/$CONFIGURATION/AndroidHostService.xpc}
if [ ! -d "$SERVICE" ]; then
  printf 'Build the app first, then pass the AndroidHostService.xpc path or set SNAPO_DERIVED_DATA.\n' >&2
  exit 1
fi
swiftc_for_tests -swift-version 6 -parse-as-library Snap-O/Device/AndroidHostServiceProtocol.swift \
  StandaloneTests/AndroidHostSecurity/Client.swift -o "$OUTPUT/client"
python3 StandaloneTests/AndroidHostSecurity/signed-tests.py "$OUTPUT" "$SERVICE" "$CONFIGURATION"
