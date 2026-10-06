#!/usr/bin/env bash
# Sign bin/TSMux.app with Developer ID, notarize and staple it, then build a
# notarized .dmg — so a download from GitHub opens without Gatekeeper refusing it
# and without the user clearing a quarantine flag by hand.
#
# Developer ID needs no provisioning profile, no registered bundle id and no app
# record: the certificate is per team, so this signs any app from 4BJBDQVY6M.
# Run after scripts/build-app.sh.
# usage: devid.sh [--sign-only] [app]
#   --sign-only: sign and verify, then stop. PRs use it to prove signing without
#   waiting on notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_ONLY=
[ "${1:-}" = --sign-only ] && { SIGN_ONLY=1; shift; }

: "${ASC_KEY_ID:=238ATU74S4}"
: "${ASC_ISSUER_ID:=98c62465-9650-49ec-afe4-23318e5c1ae1}"
: "${DEVID:=Developer ID Application: Adam Hitchcock (4BJBDQVY6M)}"
: "${ASC_KEY_PATH:=$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"

APP="${1:-bin/TSMux.app}"
VERSION="$(tr -d '[:space:]' < VERSION)"
ZIP="bin/TSMux-$VERSION-macos.zip"
DMG="bin/TSMux-$VERSION.dmg"

[ -d "$APP" ] || { echo "no $APP — run scripts/build-app.sh first" >&2; exit 1; }
[ -n "$SIGN_ONLY" ] || [ -f "$ASC_KEY_PATH" ] || { echo "no ASC key at $ASC_KEY_PATH" >&2; exit 1; }

notarize() {
  xcrun notarytool submit "$1" --wait \
    --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID"
}

# Nested code is not covered by a signature made over the bundle before it, so
# it signs first — and Sparkle's helpers before the framework that contains
# them. Notarization rejects the bundle otherwise.
echo "==> signing (Developer ID, hardened runtime)"
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for inner in \
  "$SPK/XPCServices/Downloader.xpc" \
  "$SPK/XPCServices/Installer.xpc" \
  "$SPK/Updater.app" \
  "$SPK/Autoupdate" \
  "$APP/Contents/Frameworks/Sparkle.framework" \
  "$APP/Contents/Resources/tsmux"
do
  codesign --force --timestamp --options runtime --sign "$DEVID" "$inner"
done
codesign --force --timestamp --options runtime --sign "$DEVID" "$APP"
codesign --verify --deep --strict "$APP"
[ -z "$SIGN_ONLY" ] || { echo "signed $APP (not notarized)"; exit 0; }

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
