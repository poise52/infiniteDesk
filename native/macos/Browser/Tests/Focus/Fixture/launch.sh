#!/bin/sh
set -eu
case "${1-}" in --check|--launch) ;; *) echo 'Usage: launch.sh --check | --launch' >&2; exit 2 ;; esac
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$src/../../../../../.." && pwd)
build="$root/target/browser-focus-test"
bundle="$build/InfiniteDesk Input Fixture.app"
mkdir -p "$build/module-cache" "$bundle/Contents/MacOS"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macosx15.0" \
  -module-cache-path "$build/module-cache" "$src/main.swift" -o "$bundle/Contents/MacOS/Fixture"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.infinitedesk.tests.input-fixture</string>
<key>CFBundleName</key><string>InfiniteDesk Input Fixture</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
plutil -lint "$bundle/Contents/Info.plist"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
printf '%s\n' "$bundle"
if [ "$1" = --launch ]; then exec open "$bundle"; fi
