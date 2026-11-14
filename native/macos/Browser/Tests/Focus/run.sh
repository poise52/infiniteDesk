#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)
build="$root/target/browser-focus-test"
mkdir -p "$build"
arch=$(uname -m)
case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
cache="$root/target/browser-capture-test/module-cache"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$arch-apple-macosx15.0" \
  -module-cache-path "$cache" -D FOCUS_TESTING \
  "$root/native/macos/Browser/WindowFocus.swift" \
  "$root/native/macos/Browser/Tests/Focus/main.swift" -o "$build/focus-test"
if [ "${1-}" = --integration ]; then
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$arch-apple-macosx15.0" \
    -module-cache-path "$cache" "$root/native/macos/Browser/Tests/Focus/Fixture/main.swift" -o "$build/fixture"
  exec "$build/focus-test" --integration "$build/fixture"
fi
exec "$build/focus-test"
