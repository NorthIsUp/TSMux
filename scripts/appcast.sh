#!/usr/bin/env bash
# Generate and sign the Sparkle appcast for the current release.
#
# The feed lives at a fixed asset name on the newest release
# (releases/latest/download/appcast.xml), so the URL baked into the app never
# changes while the file behind it does. A single-item appcast is enough:
# Sparkle only has to learn that something newer than the running build exists.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
BIN="ios/.build-direct/SourcePackages/artifacts/sparkle/Sparkle/bin"
ZIP="bin/TSMux-$VERSION-macos.zip"
OUT="bin/appcast"

[ -f "$ZIP" ] || { echo "no $ZIP — run scripts/devid.sh first" >&2; exit 1; }
[ -x "$BIN/generate_appcast" ] || { echo "no Sparkle tools — run scripts/build-app.sh first" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
cp "$ZIP" "$OUT/"

# SPARKLE_ED_KEY lets CI pass the private key without a keychain; locally the
# tool finds it in the login keychain and the flag is left off.
if [ -n "${SPARKLE_ED_KEY:-}" ]; then
  printf '%s' "$SPARKLE_ED_KEY" | "$BIN/generate_appcast" --ed-key-file - \
    --download-url-prefix "https://github.com/NorthIsUp/tsmux/releases/download/v$VERSION/" \
    "$OUT"
else
  "$BIN/generate_appcast" \
    --download-url-prefix "https://github.com/NorthIsUp/tsmux/releases/download/v$VERSION/" \
    "$OUT"
fi

mv "$OUT/appcast.xml" bin/appcast.xml
rm -rf "$OUT"

# A feed that publishes but that no installed app accepts fails silently — it
# looks exactly like having no updates. Check before it ships, not after.
./scripts/check-appcast.sh bin/appcast.xml bin

echo "==> bin/appcast.xml"
cat bin/appcast.xml
