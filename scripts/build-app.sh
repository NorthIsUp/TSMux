#!/usr/bin/env bash
# Assemble TSMux.app: the Swift menu bar front end with the tsmux CLI bundled
# inside it, so the app and the daemon are always the same build.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="${1:-$ROOT/bin/TSMux.app}"
# VERSION file is the single source of truth, shared with the release workflow.
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

echo "==> building tsmux (universal)"
mkdir -p bin
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -ldflags "-X main.version=$VERSION" -o bin/tsmux-arm64 .
GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "-X main.version=$VERSION" -o bin/tsmux-amd64 .
lipo -create -output bin/tsmux bin/tsmux-arm64 bin/tsmux-amd64
rm -f bin/tsmux-arm64 bin/tsmux-amd64

echo "==> building the SSH client library"
mise run ssh:lib

echo "==> building menu bar app"
# One architecture at a time, then lipo: a multi-arch `swift build` goes
# through Xcode's build system, which on Xcode 26 cannot link the static
# TSMuxSSH xcframework into the prelinked module ("library not found for
# -ltsmuxssh"). Single-arch builds use SwiftPM's own, which can.
SLICES=()
SLICE_DIR=$(mktemp -d)
for arch in arm64 x86_64; do
  (cd macos && swift build -c release --arch "$arch")
  # Ask SwiftPM where it put the product rather than hardcoding a path: the
  # layout moved between toolchains, and a stale binary left at the old path
  # meant the copy below silently shipped an old build for hours.
  slice=$(cd macos && swift build -c release --arch "$arch" --show-bin-path)/TSMuxMenu
  if [ ! -x "$slice" ]; then
    echo "swift build reported no product at $slice" >&2
    exit 1
  fi
  newest_src=$(find macos/Sources macos/Package.swift TSMuxShell/Sources -type f -newer "$slice" -print -quit)
  if [ -n "$newest_src" ]; then
    echo "$slice is older than $newest_src — the build did not pick up changes" >&2
    exit 1
  fi
  # Copied out at once: some toolchains use one bin path for every arch.
  cp "$slice" "$SLICE_DIR/TSMuxMenu-$arch"
  SLICES+=("$SLICE_DIR/TSMuxMenu-$arch")
done
APP_BIN=$SLICE_DIR/TSMuxMenu
lipo -create -output "$APP_BIN" "${SLICES[@]}"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$APP_BIN" "$APP/Contents/MacOS/TSMux"

# The icon is generated from the same geometry as the menu bar mark, so the
# two cannot drift apart and no binary asset is checked in.
ICONSET=$(mktemp -d)/AppIcon.iconset
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp bin/tsmux "$APP/Contents/Resources/tsmux"

# Sparkle ships as a binary xcframework. SwiftPM links it but does not populate
# a bundle it did not assemble, so the framework is copied in by hand and found
# at runtime through the -rpath set in Package.swift.
SPARKLE="macos/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE" ] || { echo "no Sparkle.framework at $SPARKLE — run swift build first" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
# -R, not -a: preserves the framework's version symlinks, which codesign needs.
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TSMux</string>
  <key>CFBundleDisplayName</key><string>TSMux</string>
  <key>CFBundleIdentifier</key><string>dev.northisup.tsmux.menu</string>
  <key>CFBundleExecutable</key><string>TSMux</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION#v}</string>
  <key>CFBundleVersion</key><string>${VERSION#v}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Sparkle. The feed is a fixed asset name on the newest release, so the
       URL never changes; SUPublicEDKey is the public half of the EdDSA pair
       whose private half lives in the login keychain and in CI as a secret. -->
  <key>SUFeedURL</key><string>https://github.com/NorthIsUp/tsmux/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>SEebdGvE5oDNyriWJ8nAnln9mG+X4F+2BiR5n/a3Kmw=</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

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
echo "==> floor: macOS $plist_floor (plist and binary agree)"

echo "==> signing (ad-hoc)"
# Inner code first, and Sparkle's helpers before the framework that holds them:
# a signature over a bundle does not cover a nested executable signed after it.
for inner in \
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
  "$APP/Contents/Frameworks/Sparkle.framework" \
  "$APP/Contents/Resources/tsmux"
do
  codesign --force --sign - --timestamp=none "$inner"
done
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "built $APP ($VERSION)"
