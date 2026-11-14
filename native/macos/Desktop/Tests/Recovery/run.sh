#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)
build="$root/target/desktop-recovery-tests"
mkdir -p "$build"
arch=$(uname -m)
case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$arch-apple-macosx15.0" \
  -module-cache-path "$build/module-cache" \
  "$root/native/macos/Desktop/DesktopWindows.swift" \
  "$root/native/macos/Desktop/DesktopObservation.swift" \
  "$root/native/macos/Desktop/DesktopCamera.swift" \
  "$root/native/macos/Desktop/DesktopCameraJournal.swift" \
  "$root/native/macos/Desktop/DesktopCameraRecovery.swift" \
  "$root/native/macos/Desktop/Tests/Recovery/main.swift" -o "$build/desktop-recovery-tests"
exec "$build/desktop-recovery-tests"
