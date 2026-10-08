#!/usr/bin/env bash
# Build the Go core (./mobile) as a static TSMuxCore.xcframework for the packet
# tunnel extension: iOS device and Apple-silicon simulator slices, and a
# universal macOS slice for the App Store Mac app.
set -euo pipefail
cd "$(dirname "$0")/.."

ios_min=26.0
mac_min=26.0
out=ios/Frameworks/TSMuxCore.xcframework
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

archive() { # sdk goos goarch clang-triple out-dir
  local sdk=$1 goos=$2 goarch=$3 triple=$4 dir=$5
  local sysroot cc
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  cc=$(xcrun --sdk "$sdk" -f clang)
  mkdir -p "$dir"
  CGO_ENABLED=1 GOOS=$goos GOARCH=$goarch CC="$cc" \
    CGO_CFLAGS="-isysroot $sysroot -target $triple -fembed-bitcode=off" \
    CGO_LDFLAGS="-isysroot $sysroot -target $triple" \
    go build -trimpath -ldflags="-s -w" -buildmode=c-archive -o "$dir/libtsmux.a" ./mobile
}

headers() { # dir
  mkdir -p "$1/include"
  mv "$1/libtsmux.h" "$1/include/TSMuxCore.h"
  cat >"$1/include/module.modulemap" <<'MAP'
module TSMuxCore {
  header "TSMuxCore.h"
  link "resolv"
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
lipo -create -output "$work/macosx/libtsmux.a" "$work/mac-arm64/libtsmux.a" "$work/mac-amd64/libtsmux.a"
mv "$work/mac-arm64/libtsmux.h" "$work/macosx/libtsmux.h"
headers "$work/macosx"

rm -rf "$out"
xcodebuild -create-xcframework \
  -library "$work/iphoneos/libtsmux.a" -headers "$work/iphoneos/include" \
  -library "$work/iphonesimulator/libtsmux.a" -headers "$work/iphonesimulator/include" \
  -library "$work/macosx/libtsmux.a" -headers "$work/macosx/include" \
  -output "$out" >/dev/null
echo "built $out"
