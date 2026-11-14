#!/bin/sh
set -eu

if [ "$(uname -s)" != Darwin ]; then
    echo 'This script requires macOS.' >&2
    exit 1
fi

case "$#:${1-}" in
    0:)      name=InfiniteDesk; id=dev.infinitedesk.demo; mode=desktop ;;
    1:--board) name='InfiniteDesk Board'; id=dev.infinitedesk.board; mode=board ;;
    *) echo "Usage: $0 [--board]" >&2; exit 2 ;;
esac

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
target="$root/target"
app="$target/$name.app"
builds="$target/InfiniteDesk-builds"
marker="InfiniteDesk local $mode bundle"
identity=${INFINITEDESK_SIGN_IDENTITY:--}

# Only replace links published by this script (including the earlier board build).
if [ -L "$app" ]; then
    case $(readlink "$app") in
        "InfiniteDesk-builds/build."*"/$name.app") ;;
        *) echo "Refusing to replace unrecognized link: $app" >&2; exit 1 ;;
    esac
    previous=$(cat "$app/Contents/Resources/build-marker.txt" 2>/dev/null) || previous=
    if [ "$previous" != "$marker" ] && ! { [ "$mode" = desktop ] && [ "$previous" = 'InfiniteDesk local demo bundle' ]; }; then
        echo "Refusing to replace unrecognized bundle: $app" >&2; exit 1
    fi
    [ "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" = "$id" ] || exit 1
elif [ -e "$app" ]; then
    echo "Refusing to replace non-link destination: $app" >&2
    exit 1
fi

mkdir -p "$builds"
build=$(mktemp -d "$builds/build.XXXXXX")
bundle="$build/$name.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cd "$root"
if [ "$mode" = desktop ]; then
    xcrun swiftc -swift-version 6 -warnings-as-errors -O -target "$(uname -m)-apple-macosx15.0" \
        -module-cache-path "$target/native-module-cache" native/macos/Desktop/*.swift \
        -o "$bundle/Contents/MacOS/InfiniteDesk"
else
    cargo build --target-dir "$target" --release --locked -p desk-app --features native-browser -j 2
    mkdir -p "$bundle/Contents/Frameworks"
    cp "$target/release/desk-app" "$bundle/Contents/MacOS/InfiniteDesk"
    cp "$target/release/libDeskBrowser.dylib" "$bundle/Contents/Frameworks/libDeskBrowser.dylib"
    codesign --force --sign "$identity" "$bundle/Contents/Frameworks/libDeskBrowser.dylib"
fi

printf '%s\n' "$marker" > "$bundle/Contents/Resources/build-marker.txt"
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>InfiniteDesk</string>
    <key>CFBundleIdentifier</key><string>$id</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundleDisplayName</key><string>$name</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
if [ "$mode" = desktop ]; then
    plutil -insert LSUIElement -bool YES "$bundle/Contents/Info.plist"
fi
codesign --force --sign "$identity" "$bundle"
codesign --verify --strict "$bundle"

ln -s "InfiniteDesk-builds/$(basename "$build")/$name.app" "$build/latest"
mv -fh "$build/latest" "$app"
printf 'Built %s\n' "$app"
