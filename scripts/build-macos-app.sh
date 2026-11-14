#!/bin/sh
set -eu

if [ "$(uname -s)" != Darwin ]; then
    echo 'This script requires macOS.' >&2
    exit 1
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
target="$root/target"
app="$target/InfiniteDesk.app"
builds="$target/InfiniteDesk-builds"
mkdir -p "$builds"
cd "$root"
cargo build --manifest-path "$root/Cargo.toml" --target-dir "$target" --release --locked -p desk-app --features native-browser -j 2

build=$(mktemp -d "$builds/build.XXXXXX")
bundle="$build/InfiniteDesk.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Frameworks"
cp "$target/release/desk-app" "$bundle/Contents/MacOS/InfiniteDesk"
cp "$target/release/libDeskBrowser.dylib" "$bundle/Contents/Frameworks/libDeskBrowser.dylib"
codesign --force --sign - "$bundle/Contents/Frameworks/libDeskBrowser.dylib"
printf 'InfiniteDesk local demo bundle\n' > "$bundle/Contents/Resources/build-marker.txt"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>InfiniteDesk</string>
    <key>CFBundleIdentifier</key><string>dev.infinitedesk.demo</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>InfiniteDesk</string>
    <key>CFBundleDisplayName</key><string>InfiniteDesk</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"

if [ -L "$app" ]; then
    case $(readlink "$app") in
        InfiniteDesk-builds/build.*/InfiniteDesk.app) ;;
        *) echo "Refusing to replace unrecognized link: $app" >&2; exit 1 ;;
    esac
    [ "$(cat "$app/Contents/Resources/build-marker.txt" 2>/dev/null)" = 'InfiniteDesk local demo bundle' ] &&
        [ "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" 2>/dev/null)" = 'dev.infinitedesk.demo' ] || {
        echo "Refusing to replace unrecognized bundle: $app" >&2; exit 1;
    }
elif [ -e "$app" ]; then
    echo "Refusing to replace non-link destination: $app" >&2
    exit 1
fi

ln -s "InfiniteDesk-builds/$(basename "$build")/InfiniteDesk.app" "$build/latest"
mv -fh "$build/latest" "$app"
printf 'Built %s\n' "$app"
