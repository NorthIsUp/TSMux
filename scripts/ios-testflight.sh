#!/bin/sh
# Archive, sign and export TSMux for iOS, then upload it to TestFlight, on a build Mac or in CI.
# From template-apple's testflight.sh, with a second profile for the tunnel extension.
# usage: ios-testflight.sh [--no-upload]
#   --no-upload: export the .ipa (+ AppStoreInfo.plist for Linux Transporter) and stop. CI uses this
#   and uploads from Linux.
# env (none are secret): ASC_KEY_ID (238ATU74S4), ASC_ISSUER_ID
#   optional: CI_KEYCHAIN (ci.keychain-db), INTERNAL_ONLY (1), OUT (build/testflight)
# Signing is manual: the Apple Distribution identity and both "TSMux … App Store" profiles must
# already be installed (CI: ci-keychain.sh; locally: the login keychain and Xcode's profiles dir).
set -eu

UPLOAD=1
[ "${1:-}" = --no-upload ] && UPLOAD=
: "${ASC_KEY_ID:=238ATU74S4}" "${ASC_ISSUER_ID:=98c62465-9650-49ec-afe4-23318e5c1ae1}"
cd "$(dirname "$0")/../ios"
SCHEME=TSMux BUNDLE_ID=dev.northisup.tsmux TEAM_ID=4BJBDQVY6M
KC=${CI_KEYCHAIN:-ci.keychain-db}
PASSFILE=$HOME/.appstoreconnect/${KC%.keychain-db}.pass
OUT=${OUT:-build/testflight}
# Internal-only builds skip Beta App Review and can never be offered to external testers.
INTERNAL=$([ "${INTERNAL_ONLY:-1}" = 1 ] && echo true || echo false)

rm -rf "$OUT" && mkdir -p "$OUT"
[ ! -f "$PASSFILE" ] || security unlock-keychain -p "$(cat "$PASSFILE")" "$KC"
(cd .. && mise run ios:core ios:gen)

# A UTC timestamp build number never collides with an earlier upload, from any machine.
xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -destination generic/platform=iOS -archivePath "$OUT/$SCHEME.xcarchive" \
  CURRENT_PROJECT_VERSION="$(date -u +%Y%m%d%H%M)" archive -quiet

# Linux Transporter can't analyze an .ipa itself and needs AppStoreInfo.plist beside it.
cat > "$OUT/export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>generateAppStoreInformation</key><true/>
  <key>testFlightInternalTestingOnly</key><$INTERNAL/>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key><dict>
    <key>$BUNDLE_ID</key><string>TSMux App Store</string>
    <key>$BUNDLE_ID.tunnel</key><string>TSMux Tunnel App Store</string>
  </dict>
</dict></plist>
EOF
# The export shells out to rsync and fails with "Copy failed" under Homebrew's rsync 3.x.
PATH=/usr/bin:$PATH xcodebuild -exportArchive -archivePath "$OUT/$SCHEME.xcarchive" \
  -exportOptionsPlist "$OUT/export.plist" -exportPath "$OUT"

[ -n "$UPLOAD" ] || exit 0
xcrun altool --upload-app -t ios -f "$OUT/$SCHEME.ipa" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
