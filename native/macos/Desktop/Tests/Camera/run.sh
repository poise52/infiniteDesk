#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)
build="$root/target/desktop-camera-tests"
mkdir -p "$build"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macosx15.0" \
  -module-cache-path "$build/module-cache" \
  "$root/native/macos/Desktop/DesktopWindows.swift" \
  "$root/native/macos/Desktop/DesktopObservation.swift" \
  "$root/native/macos/Desktop/DesktopCamera.swift" \
  "$root/native/macos/Desktop/DesktopCameraJournal.swift" \
  "$root/native/macos/Desktop/DesktopCameraRecovery.swift" \
  "$root/native/macos/Desktop/Tests/Camera/main.swift" -o "$build/tests"
exec "$build/tests"
