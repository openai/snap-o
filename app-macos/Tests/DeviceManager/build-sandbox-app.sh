#!/bin/bash
set -euo pipefail

APP_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUTPUT=${1:?Usage: build-sandbox-app.sh /absolute/output-directory}
IDENTITY=${DEVICE_MANAGER_SIGNING_IDENTITY:?Set DEVICE_MANAGER_SIGNING_IDENTITY to an Apple Development signing identity}
CONFIGURATION=${SNAPO_TEST_CONFIGURATION:-Release}
case "$CONFIGURATION" in
  Debug|Release) ;;
  *) printf 'Unsupported configuration: %s\n' "$CONFIGURATION" >&2; exit 2 ;;
esac
BUNDLE_ID=com.openai.snapo.device-manager-test
mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd)
DERIVED_DATA=${SNAPO_TEST_DERIVED_DATA:-$OUTPUT/DerivedData}

xcodebuild -project "$APP_ROOT/Snap-O.xcodeproj" -scheme Snap-O \
  -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  SNAPO_APP_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build > "$OUTPUT/build.log" 2>&1

APP="$OUTPUT/Snap-O.app"
ditto "$DERIVED_DATA/Build/Products/$CONFIGURATION/Snap-O.app" "$APP"
python3 - "$APP_ROOT/Snap-O/SnapO.entitlements" "$OUTPUT/app.entitlements" "$BUNDLE_ID" <<'PY'
import pathlib
import plistlib
import sys
source, destination, bundle_id = sys.argv[1:]
text = pathlib.Path(source).read_text().replace('$(PRODUCT_BUNDLE_IDENTIFIER)', bundle_id)
entitlements = plistlib.loads(text.encode())
assert entitlements.get('com.apple.security.app-sandbox') is True
pathlib.Path(destination).write_bytes(plistlib.dumps(entitlements))
PY

# Sign nested code before sealing the containing app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  for component in "$SPARKLE"/Versions/B/XPCServices/*.xpc \
    "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
    if [ -e "$component" ]; then
      codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
        --preserve-metadata=entitlements "$component"
    fi
  done
fi
for library in "$APP"/Contents/MacOS/*.dylib; do
  if [ -f "$library" ]; then
    codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$library"
  fi
done
for cli in snapo snapo-network snapo-tweaks; do
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Contents/MacOS/$cli"
done
SERVICE="$APP/Contents/XPCServices/EmulatorService.xpc"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$SERVICE"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements "$OUTPUT/app.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

python3 - "$APP" "$SERVICE" "$BUNDLE_ID" <<'PY'
import pathlib
import plistlib
import subprocess
import sys
app, service = map(pathlib.Path, sys.argv[1:3])
bundle_id = sys.argv[3]
for bundle, sandboxed in [(app, True), (service, False)]:
    result = subprocess.run(
        ['codesign', '-d', '--entitlements', ':-', str(bundle)],
        check=True, capture_output=True,
    )
    entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else {}
    assert bool(entitlements.get('com.apple.security.app-sandbox')) == sandboxed, bundle
with (service / 'Contents/Info.plist').open('rb') as file:
    info = plistlib.load(file)
assert info['CFBundleIdentifier'] == bundle_id + '.EmulatorService'
assert info['XPCService']['ServiceType'] == 'Application'
assert sorted(path.name for path in (app / 'Contents/XPCServices').iterdir()) == ['EmulatorService.xpc']
PY
printf '%s\n' "$APP"
