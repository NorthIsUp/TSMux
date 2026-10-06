#!/bin/bash
# Installs a signing identity into a dedicated keychain that SSH sessions and CI can unlock without a prompt.
# stdin: line 1 = the .p12 password, then the .p12 as base64. Run once per identity (distribution, development).
# env: CI_KEYCHAIN (default ci.keychain-db); CI_KEYCHAIN_PASS_FILE (default ~/.appstoreconnect/<keychain>.pass).
set -euo pipefail
KC=${CI_KEYCHAIN:-ci.keychain-db}
PASSFILE=${CI_KEYCHAIN_PASS_FILE:-$HOME/.appstoreconnect/${KC%.keychain-db}.pass}
P12=$(mktemp)
trap 'rm -f "$P12" "$P12.cer"' EXIT

read -r P12PASS
base64 -D > "$P12"

umask 077
mkdir -p "$(dirname "$PASSFILE")"
[ -f "$PASSFILE" ] || openssl rand -hex 24 > "$PASSFILE"
KCPASS=$(cat "$PASSFILE")

security create-keychain -p "$KCPASS" "$KC" 2>/dev/null || true
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
# Without -f pkcs12, import guesses the format and fails with "Unknown format in import".
security import "$P12" -f pkcs12 -k "$KC" -P "$P12PASS" -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild
# Without Apple's WWDR G3 intermediate the identity imports but find-identity shows 0 valid.
curl -fsSL https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer -o "$P12.cer"
security import "$P12.cer" -k "$KC" -T /usr/bin/codesign >/dev/null 2>&1 || true
# Without the partition list, codesign blocks on a GUI prompt that SSH and CI can never answer.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null
security list-keychains -d user -s "$KC" login.keychain-db
security find-identity -v -p codesigning "$KC"
