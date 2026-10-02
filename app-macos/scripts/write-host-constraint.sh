#!/bin/sh
set -eu
CONSTRAINT=${1:?Usage: write-host-constraint.sh output app-identifier team-identifier}
APP_IDENTIFIER=${2:?Missing app identifier}
# Unsigned Release builds have no team and cannot launch the helper.
TEAM_IDENTIFIER=${3?Missing team identifier}

/usr/bin/plutil -create xml1 "$CONSTRAINT"
/usr/bin/plutil -insert signing-identifier -string "$APP_IDENTIFIER" "$CONSTRAINT"
/usr/bin/plutil -insert team-identifier -string "$TEAM_IDENTIFIER" "$CONSTRAINT"
/usr/bin/codesign --validate-constraint "$CONSTRAINT"
