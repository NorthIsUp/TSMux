#!/usr/bin/env bash
# Build bin/tsmux, the universal macOS CLI that both Mac apps bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
mkdir -p bin
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -ldflags "-X main.version=$VERSION" -o bin/tsmux-arm64 .
GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "-X main.version=$VERSION" -o bin/tsmux-amd64 .
rm -f bin/tsmux
lipo -create -output bin/tsmux bin/tsmux-arm64 bin/tsmux-amd64
rm -f bin/tsmux-arm64 bin/tsmux-amd64
