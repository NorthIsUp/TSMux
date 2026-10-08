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

# sysextd's own checks, which otherwise only run when a user tries to connect.
SYSX="$APP/Contents/Library/SystemExtensions/dev.northisup.tsmux.menu.tunnel.systemextension"
[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundlePackageType" "$SYSX/Contents/Info.plist")" = SYSX ] ||
  { echo "the system extension's CFBundlePackageType is not SYSX" >&2; exit 1; }
mach=$(/usr/libexec/PlistBuddy -c "Print :NetworkExtension:NEMachServiceName" "$SYSX/Contents/Info.plist")
ents=$(mktemp)
codesign -d --entitlements - --xml "$SYSX" > "$ents" 2>/dev/null
groups=$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$ents" | sed '1d;$d')
rm -f "$ents"
ok=
for g in $groups; do case "$mach" in "$g".*) ok=1 ;; esac; done
[ -n "$ok" ] || { echo "NEMachServiceName $mach starts with none of: $groups" >&2; exit 1; }
echo "built $APP ($BUILD_VERSION)"
