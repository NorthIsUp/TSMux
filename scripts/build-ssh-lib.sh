#!/usr/bin/env bash
# Build ./shellcore (the SSH client) as TSMuxShell/TSMuxSSH.xcframework: iOS
# device and simulator slices, and a universal macOS slice for the menu bar app.
set -euo pipefail
cd "$(dirname "$0")/.."

ios_min=26.0
mac_min=26.0
out=TSMuxShell/TSMuxSSH.xcframework
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

archive() { # sdk goos goarch clang-triple out-dir
  local sdk=$1 goos=$2 goarch=$3 triple=$4 dir=$5
  local sysroot cc
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  cc=$(xcrun --sdk "$sdk" -f clang)
  mkdir -p "$dir"
  CGO_ENABLED=1 GOOS=$goos GOARCH=$goarch CC="$cc" \
    CGO_CFLAGS="-isysroot $sysroot -target $triple" \
    CGO_LDFLAGS="-isysroot $sysroot -target $triple" \
    go build -trimpath -ldflags="-s -w" -buildmode=c-archive -o "$dir/libtsmuxssh.a" ./shellcore
}

# Headers live under include/TSMuxSSH/ so the module map doesn't land on the
# same path as TSMuxCore's when Xcode copies both into the products dir.
headers() { # dir
  mkdir -p "$1/include/TSMuxSSH"
  mv "$1/libtsmuxssh.h" "$1/include/TSMuxSSH/TSMuxSSH.h"
  cat >"$1/include/TSMuxSSH/module.modulemap" <<'MAP'
module TSMuxSSH {
  header "TSMuxSSH.h"
  export *
}
MAP
}

archive iphoneos ios arm64 "arm64-apple-ios$ios_min" "$work/iphoneos"
headers "$work/iphoneos"
archive iphonesimulator ios arm64 "arm64-apple-ios$ios_min-simulator" "$work/iphonesimulator"
headers "$work/iphonesimulator"

archive macosx darwin arm64 "arm64-apple-macos$mac_min" "$work/mac-arm64"
archive macosx darwin amd64 "x86_64-apple-macos$mac_min" "$work/mac-amd64"
mkdir -p "$work/macosx"
lipo -create -output "$work/macosx/libtsmuxssh.a" "$work/mac-arm64/libtsmuxssh.a" "$work/mac-amd64/libtsmuxssh.a"
mv "$work/mac-arm64/libtsmuxssh.h" "$work/macosx/libtsmuxssh.h"
headers "$work/macosx"

rm -rf "$out"
xcodebuild -create-xcframework \
  -library "$work/iphoneos/libtsmuxssh.a" -headers "$work/iphoneos/include" \
  -library "$work/iphonesimulator/libtsmuxssh.a" -headers "$work/iphonesimulator/include" \
  -library "$work/macosx/libtsmuxssh.a" -headers "$work/macosx/include" \
  -output "$out" >/dev/null
echo "built $out"
