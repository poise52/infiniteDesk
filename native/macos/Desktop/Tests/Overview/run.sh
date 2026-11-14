#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)
build="$root/target/desktop-overview-tests"
mkdir -p "$build"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macosx15.0" \
  -module-cache-path "$build/module-cache" \
  "$root/native/macos/Desktop/DesktopOverviewGeometry.swift" \
  "$root/native/macos/Desktop/Tests/Overview/main.swift" -o "$build/tests"
exec "$build/tests"
