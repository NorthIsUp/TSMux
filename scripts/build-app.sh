#!/usr/bin/env bash
# Build bin/TSMux.app, the GitHub-release edition: the TSMuxDirect target of
# ios/project.yml, Developer ID signed, with its system extension and the tsmux
# CLI inside. scripts/devid.sh notarizes it and builds the dmg.
# usage: build-app.sh [--unsigned] [app]
#   --unsigned: compile only, for CI without the Developer ID secrets.
# BUILD_VERSION overrides CFBundleVersion; `mise run dev` makes it unique so
# macOS replaces the running system extension.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
UNSIGNED=
[ "${1:-}" = --unsigned ] && { UNSIGNED=1; shift; }
APP="${1:-$ROOT/bin/TSMux.app}"
# VERSION file is the single source of truth, shared with the release workflow.
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_VERSION="${BUILD_VERSION:-$VERSION}"
DERIVED="$ROOT/ios/.build-direct"
ARCHIVE="$DERIVED/TSMux.xcarchive"

echo "==> building tsmux (universal)"
./scripts/build-cli.sh

echo "==> building the Go core and the SSH client library"
mise run ios:core
mise run ssh:lib
mise run ios:gen

VERSIONS=(MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_VERSION")
if [ -n "$UNSIGNED" ]; then
  echo "==> compiling (unsigned)"
  xcodebuild build -project ios/TSMux.xcodeproj -scheme TSMuxDirect -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
    "${VERSIONS[@]}" CODE_SIGNING_ALLOWED=NO -quiet
  echo "compiled TSMuxDirect ($BUILD_VERSION), not signed"
  exit 0
fi

echo "==> archiving"
rm -rf "$ARCHIVE"
xcodebuild archive -project ios/TSMux.xcodeproj -scheme TSMuxDirect -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" \
  "${VERSIONS[@]}" -quiet

echo "==> exporting (Developer ID)"
EXPORT="$DERIVED/export"
rm -rf "$EXPORT"
cat > "$DERIVED/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>4BJBDQVY6M</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>dev.northisup.tsmux.menu</key><string>TSMux Direct</string>
    <key>dev.northisup.tsmux.menu.tunnel</key><string>TSMux Direct Tunnel</string>
  </dict>
</dict>
</plist>
PLIST
# Homebrew's rsync breaks the export's copy step ("Copy failed").
PATH="/usr/bin:$PATH" xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$DERIVED/ExportOptions.plist" -exportPath "$EXPORT" -quiet

rm -rf "$APP"
ditto "$EXPORT/TSMux.app" "$APP"

# The floor is declared in two places — this plist and the binary's own
# LC_BUILD_VERSION — with nothing tying them together. When they disagree the
# app passes Launch Services and dies in dyld, and because it is LSUIElement
# the user sees nothing happen at all.
plist_floor=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
binary_floor=$(otool -l "$APP/Contents/MacOS/TSMux" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
if [ "$plist_floor" != "$binary_floor" ]; then
  echo "Info.plist says macOS $plist_floor but the binary is built for $binary_floor" >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"

# What sysextd and nesessionmanager require of a Developer ID packet tunnel,
# which otherwise only surfaces one refusal at a time when a user connects.
SYSX="$APP/Contents/Library/SystemExtensions/dev.northisup.tsmux.menu.tunnel.systemextension"
fail() { echo "system extension: $*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
ents() { codesign -d --entitlements - --xml "$1" 2>/dev/null > "$2"; }
[ -d "$SYSX" ] || fail "missing at $SYSX"
[ "$(plist "$SYSX" CFBundlePackageType)" = SYSX ] || fail "CFBundlePackageType is not SYSX"
[ "$(plist "$SYSX" CFBundleIdentifier).systemextension" = "$(basename "$SYSX")" ] ||
  fail "bundle name is not its identifier"
[ -n "$(plist "$SYSX" NSSystemExtensionUsageDescription)" ] || fail "no NSSystemExtensionUsageDescription"
plist "$SYSX" "NetworkExtension:NEProviderClasses:com.apple.networkextension.packet-tunnel" >/dev/null ||
  fail "no packet-tunnel provider class"
for b in "$APP" "$SYSX"; do
  [ -f "$b/Contents/embedded.provisionprofile" ] || fail "no embedded profile in $b"
done
tmp=$(mktemp -d)
ents "$APP" "$tmp/app.plist"
ents "$SYSX" "$tmp/sysx.plist"
for f in app sysx; do
  /usr/libexec/PlistBuddy -c "Print :com.apple.developer.networking.networkextension" "$tmp/$f.plist" |
    grep -qx ' *packet-tunnel-provider-systemextension' ||
    fail "$f lacks the packet-tunnel-provider-systemextension entitlement"
done
[ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.developer.system-extension.install" "$tmp/app.plist")" = true ] ||
  fail "the app lacks com.apple.developer.system-extension.install"
[ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$tmp/sysx.plist")" = true ] ||
  fail "the extension is not sandboxed"
mach=$(plist "$SYSX" NetworkExtension:NEMachServiceName)
groups=$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$tmp/sysx.plist" | sed '1d;$d')
rm -rf "$tmp"
ok=
for g in $groups; do case "$mach" in "$g".*) ok=1 ;; esac; done
[ -n "$ok" ] || fail "NEMachServiceName $mach starts with none of: $groups"
echo "built $APP ($BUILD_VERSION)"
