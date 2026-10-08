#!/usr/bin/env bash
# Notarize and staple bin/TSMux.app, then build a notarized .dmg — so a
# download from GitHub opens without Gatekeeper refusing it and without the
# user clearing a quarantine flag by hand.
#
# Run after scripts/build-app.sh.
# usage: devid.sh [--sign-only] [app]
#   --sign-only: verify the signature, then stop. PRs use it to prove signing
#   without waiting on notarization.
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

# scripts/build-app.sh exported the app already signed: Xcode signs the system
# extension, Sparkle and the CLI with their own entitlements and profiles, and
# signing again here would strip them.
echo "==> checking the Developer ID signature"
codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -q "^Authority=Developer ID Application" ||
  { echo "$APP is not Developer ID signed" >&2; exit 1; }
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
