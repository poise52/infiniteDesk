#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
arch=$(uname -m)
case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
build="$root/target/browser-capture-test"
mkdir -p "$build"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$arch-apple-macosx15.0" \
  -module-cache-path "$build/module-cache" -D CAPTURE_TESTING \
  "$root/native/macos/Browser/WindowCapture.swift" \
  "$root/native/macos/Browser/WindowFocus.swift" \
  "$root/native/macos/Browser/BrowserTextInput.swift" \
  "$root/native/macos/Browser/PickerCoordinator.swift" \
  "$root/native/macos/Browser/Tests/main.swift" -o "$build/capture-test"
"$build/capture-test"
