#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)
build="$root/target/browser-native-test"
mkdir -p "$build"
arch=$(uname -m)
case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$arch-apple-macosx15.0" \
  -module-cache-path "$build/module-cache" \
  "$root/native/macos/Browser/WindowFocus.swift" \
  "$root/native/macos/Browser/NativeWindowPlacement.swift" \
  "$root/native/macos/Browser/Tests/Native/main.swift" -o "$build/native-test"
if [ "${1-}" = --integration ]; then
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$arch-apple-macosx15.0" \
    -module-cache-path "$build/module-cache" \
    "$root/native/macos/Browser/Tests/Focus/Fixture/main.swift" -o "$build/fixture"
  exec "$build/native-test" --integration "$build/fixture"
fi
exec "$build/native-test"
