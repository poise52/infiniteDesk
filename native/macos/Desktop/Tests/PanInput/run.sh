#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)
build="$root/target/desktop-pan-input-tests"
mkdir -p "$build"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macosx15.0" \
  -module-cache-path "$build/module-cache" \
  "$root/native/macos/Desktop/DesktopPanInput.swift" \
  "$root/native/macos/Desktop/Tests/PanInput/main.swift" -o "$build/tests"
exec "$build/tests"
