#!/usr/bin/env bash
# Sign bin/TSMux.app with Developer ID, notarize and staple it, then build a
# notarized .dmg — so a download from GitHub opens without Gatekeeper refusing it
# and without the user clearing a quarantine flag by hand.
#
# Developer ID needs no provisioning profile, no registered bundle id and no app
# record: the certificate is per team, so this signs any app from 4BJBDQVY6M.
# Run after scripts/build-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ASC_KEY_ID:=238ATU74S4}"
: "${ASC_ISSUER_ID:=98c62465-9650-49ec-afe4-23318e5c1ae1}"
: "${DEVID:=Developer ID Application: Adam Hitchcock (4BJBDQVY6M)}"
: "${ASC_KEY_PATH:=$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"

APP="${1:-bin/TSMux.app}"
VERSION="$(tr -d '[:space:]' < VERSION)"
ZIP="bin/TSMux-$VERSION-macos.zip"
DMG="bin/TSMux-$VERSION.dmg"

[ -d "$APP" ] || { echo "no $APP — run scripts/build-app.sh first" >&2; exit 1; }
[ -f "$ASC_KEY_PATH" ] || { echo "no ASC key at $ASC_KEY_PATH" >&2; exit 1; }

notarize() {
  xcrun notarytool submit "$1" --wait \
    --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID"
}

# The bundled CLI is a second Mach-O and is not covered by a signature made over
# the bundle before it — nested code signs first, or --deep --strict rejects it.
echo "==> signing (Developer ID, hardened runtime)"
codesign --force --timestamp --options runtime --sign "$DEVID" "$APP/Contents/Resources/tsmux"
codesign --force --timestamp --options runtime --sign "$DEVID" "$APP"
codesign --verify --deep --strict "$APP"

# notarytool takes an archive; stapler writes the ticket into the .app. So the
# zip is rebuilt from the stapled bundle, or the download has no ticket in it.
echo "==> notarizing the app"
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP"
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> building + notarizing the dmg"
rm -rf bin/dmg "$DMG"
mkdir bin/dmg
cp -R "$APP" bin/dmg/
ln -s /Applications bin/dmg/Applications
hdiutil create -quiet -volname TSMux -srcfolder bin/dmg -format UDZO "$DMG"
rm -rf bin/dmg
codesign --timestamp --sign "$DEVID" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# Assess the way a user's Mac will, not the way a signed-in developer's does.
echo "==> gatekeeper assessment"
spctl --assess --type execute -vv "$APP"
spctl --assess --type open --context context:primary-signature -vv "$DMG"

echo "built $ZIP and $DMG"
