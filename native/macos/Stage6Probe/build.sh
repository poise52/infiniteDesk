#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
src="$root/native/macos/Stage6Probe"
out="$root/target/native-probe"
mkdir -p "$out/build/module-cache" "$out/InfiniteDesk Fixture.app/Contents/MacOS" "$out/InfiniteDesk Probe.app/Contents/MacOS"
cp "$src/Fixture.swift" "$out/build/main.swift"
xcrun swiftc -module-cache-path "$out/build/module-cache" -swift-version 6 -warnings-as-errors -O -target arm64-apple-macosx15.0 "$src/Shared.swift" "$out/build/main.swift" -o "$out/InfiniteDesk Fixture.app/Contents/MacOS/Fixture"
cp "$src/Probe.swift" "$out/build/main.swift"
xcrun swiftc -module-cache-path "$out/build/module-cache" -swift-version 6 -warnings-as-errors -O -target arm64-apple-macosx15.0 "$src/Shared.swift" "$out/build/main.swift" -o "$out/InfiniteDesk Probe.app/Contents/MacOS/Probe"
cp "$src/Tests.swift" "$out/build/main.swift"
xcrun swiftc -module-cache-path "$out/build/module-cache" -swift-version 6 -warnings-as-errors -target arm64-apple-macosx15.0 "$src/Shared.swift" "$out/build/main.swift" -o "$out/build/tests"
"$out/build/tests"
for name in Fixture Probe; do
    bundle="$out/InfiniteDesk $name.app"
    case "$name" in Fixture) identifier=org.infinitedesk.stage6.fixture;; Probe) identifier=org.infinitedesk.stage6.probe;; esac
    cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleName</key><string>InfiniteDesk $name</string>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
    codesign --force --sign - "$bundle"
    codesign --verify --strict "$bundle"
done
printf 'Built %s\n' "$out"
