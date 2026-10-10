#!/usr/bin/env bash
# CI only: puts the App Store Connect key, the Developer ID identity and the
# Mac app's Developer ID profiles where build-app.sh and devid.sh expect them.
# The profiles are what let a Developer ID app carry a system extension.
#
# Nothing here is cached: a cached keychain is readable by any later run on any
# branch, including from a fork's PR.
set -euo pipefail
: "${ASC_KEY_P8:?}" "${DEVID_P12:?}" "${P12_PASSWORD:?}" "${RUNNER_TEMP:?}"
: "${DIRECT_APP_PROFILE_BASE64:?}" "${DIRECT_TUNNEL_PROFILE_BASE64:?}"
: "${ASC_KEY_ID:=238ATU74S4}"

mkdir -p ~/.appstoreconnect/private_keys
printf '%s' "$ASC_KEY_P8" > ~/.appstoreconnect/private_keys/"AuthKey_$ASC_KEY_ID.p8"
chmod 600 ~/.appstoreconnect/private_keys/"AuthKey_$ASC_KEY_ID.p8"

keychain="$RUNNER_TEMP/signing.keychain-db"
pass=$(uuidgen)
security create-keychain -p "$pass" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$pass" "$keychain"

# The identity reads as invalid — 0 valid identities — until Apple's WWDR
# intermediate is in the same keychain to chain it to.
curl -fsSL -o "$RUNNER_TEMP/wwdr.cer" https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
security import "$RUNNER_TEMP/wwdr.cer" -k "$keychain"

printf '%s' "$DEVID_P12" | base64 -D > "$RUNNER_TEMP/devid.p12"
security import "$RUNNER_TEMP/devid.p12" -f pkcs12 -k "$keychain" -P "$P12_PASSWORD" -T /usr/bin/codesign
rm -f "$RUNNER_TEMP/devid.p12"

# Without this, codesign blocks on a keychain prompt that no one can click.
security set-key-partition-list -S apple-tool:,apple: -k "$pass" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" login.keychain-db

profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$profiles"
printf '%s' "$DIRECT_APP_PROFILE_BASE64" | base64 -D > "$profiles/tsmux-direct-app.provisionprofile"
printf '%s' "$DIRECT_TUNNEL_PROFILE_BASE64" | base64 -D > "$profiles/tsmux-direct-tunnel.provisionprofile"

security find-identity -v -p codesigning "$keychain"
