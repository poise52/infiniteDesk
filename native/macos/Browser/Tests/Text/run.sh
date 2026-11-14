#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)
build="$root/target/browser-text-test"
mkdir -p "$build"
arch=$(uname -m)
case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$arch-apple-macosx15.0" \
  -module-cache-path "$build/module-cache" \
  "$root/native/macos/Browser/WindowFocus.swift" \
  "$root/native/macos/Browser/BrowserTextInput.swift" \
  "$root/native/macos/Browser/Tests/Text/main.swift" -o "$build/text-test"
exec "$build/text-test"
