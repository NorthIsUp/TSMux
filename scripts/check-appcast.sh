#!/usr/bin/env bash
# Assert an appcast is one a running copy of TSMux would actually accept.
#
# The failure this exists to catch is silent: a feed that parses, publishes and
# 404s nothing, but that every installed app rejects — or worse, accepts when it
# should not. Nothing downstream notices, because an app that cannot update just
# looks like an app with no updates.
set -euo pipefail
cd "$(dirname "$0")/.."

APPCAST="${1:-bin/appcast.xml}"
ZIPDIR="${2:-bin}"
VERSION="$(tr -d '[:space:]' < VERSION)"
fail() { echo "appcast: $*" >&2; exit 1; }

[ -f "$APPCAST" ] || fail "no $APPCAST"
xmllint --noout "$APPCAST" 2>/dev/null || fail "not well-formed XML"

x() { xmllint --xpath "$1" "$APPCAST" 2>/dev/null || true; }

items=$(x 'count(/rss/channel/item)')
[ "$items" = "1" ] || fail "expected 1 item, found ${items:-0}"

got_version=$(x 'string(/rss/channel/item/*[local-name()="version"])')
[ "$got_version" = "$VERSION" ] || fail "version is '$got_version', VERSION says '$VERSION'"

min=$(x 'string(/rss/channel/item/*[local-name()="minimumSystemVersion"])')
[ -n "$min" ] || fail "no minimumSystemVersion — every Mac would be offered the update"

url=$(x 'string(/rss/channel/item/enclosure/@url)')
zip="TSMux-$VERSION-macos.zip"
case "$url" in
  */releases/download/v"$VERSION"/"$zip") ;;
  *) fail "enclosure url does not point at v$VERSION's $zip: $url" ;;
esac

# A wrong length makes Sparkle reject the download after paying for it.
len=$(x 'string(/rss/channel/item/enclosure/@length)')
actual=$(stat -f%z "$ZIPDIR/$zip" 2>/dev/null || stat -c%s "$ZIPDIR/$zip" 2>/dev/null || echo "")
[ -n "$actual" ] || fail "no $ZIPDIR/$zip to size-check against"
[ "$len" = "$actual" ] || fail "enclosure length $len but $zip is $actual bytes"

# Sparkle accepts an update by EdDSA signature *or* by Apple code signing, and
# generate_appcast omits the EdDSA one when the archive is Developer ID signed
# and notarized. Either path is fine; neither is not.
sig=$(x 'string(/rss/channel/item/enclosure/@*[local-name()="edSignature"])')
if [ -n "$sig" ]; then
  echo "appcast: ok — $VERSION, verified by EdDSA signature"
else
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  ditto -x -k "$ZIPDIR/$zip" "$tmp" 2>/dev/null || fail "cannot unpack $zip to check its signature"
  app=$(find "$tmp" -maxdepth 1 -name "*.app" | head -1)
  [ -n "$app" ] || fail "no .app inside $zip"
  spctl --assess --type execute "$app" >/dev/null 2>&1 \
    || fail "no edSignature AND the app is not notarized — nothing could verify this update"
  echo "appcast: ok — $VERSION, verified by Apple code signing (notarized)"
fi
