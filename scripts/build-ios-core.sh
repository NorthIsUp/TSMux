#!/usr/bin/env bash
# Build the Go core (./mobile) as a static TSMuxCore.xcframework for the iOS
# packet tunnel extension: a device slice and an Apple-silicon simulator slice.
set -euo pipefail
cd "$(dirname "$0")/.."

min=26.0
out=ios/Frameworks/TSMuxCore.xcframework
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

slice() { # sdk target-triple
  local sdk=$1 triple=$2 dir="$work/$1"
  local sysroot cc
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  cc=$(xcrun --sdk "$sdk" -f clang)
  mkdir -p "$dir/include"
  CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$cc" \
    CGO_CFLAGS="-isysroot $sysroot -target $triple -fembed-bitcode=off" \
    CGO_LDFLAGS="-isysroot $sysroot -target $triple" \
    go build -trimpath -ldflags="-s -w" -buildmode=c-archive -o "$dir/libtsmux.a" ./mobile
  mv "$dir/libtsmux.h" "$dir/include/TSMuxCore.h"
  cat >"$dir/include/module.modulemap" <<'EOF'
module TSMuxCore {
  header "TSMuxCore.h"
  link "resolv"
  export *
}
EOF
}

slice iphoneos "arm64-apple-ios$min"
slice iphonesimulator "arm64-apple-ios$min-simulator"

rm -rf "$out"
xcodebuild -create-xcframework \
  -library "$work/iphoneos/libtsmux.a" -headers "$work/iphoneos/include" \
  -library "$work/iphonesimulator/libtsmux.a" -headers "$work/iphonesimulator/include" \
  -output "$out" >/dev/null
echo "built $out"
