#!/bin/sh
set -eu
case "${1-}" in --check|--run) ;; *) echo 'Usage: run.sh --check | --run' >&2; exit 2 ;; esac
[ "$#" -eq 1 ] || exit 2
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../../.." && pwd)
build="$root/target/desktop-acceptance"
bundle="$build/InfiniteDesk Acceptance.app"
identity=${INFINITEDESK_SIGN_IDENTITY-}
if [ -z "$identity" ]; then
  if [ -r "$build/build-identity" ]; then identity=$(cat "$build/build-identity"); else identity=-; fi
fi
sources=$(shasum -a 256 "$here/Driver.swift" "$here/CameraManagerDriver.swift" "$here/PanDriver.swift" "$here/Info.plist" "$here/run.sh" | shasum -a 256 | awk '{print $1}')
fingerprint=$(printf '%s\n%s\n' "$sources" "$identity" | shasum -a 256 | awk '{print $1}')
current=''
if [ -r "$build/build-fingerprint" ]; then current=$(cat "$build/build-fingerprint"); fi
if [ "$fingerprint" != "$current" ] || [ ! -x "$bundle/Contents/MacOS/Driver" ]; then
  if [ "$1" = --run ]; then
    echo 'Acceptance bundle is missing or sources changed. Run --check and review its Accessibility grant before --run.' >&2
    exit 1
  fi
  mkdir -p "$build/module-cache" "$bundle/Contents/MacOS"
  cp "$here/Driver.swift" "$build/main.swift"
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macosx15.0" \
    -module-cache-path "$build/module-cache" "$build/main.swift" "$here/CameraManagerDriver.swift" "$here/PanDriver.swift" -o "$bundle/Contents/MacOS/Driver"
  cp "$here/Info.plist" "$bundle/Contents/Info.plist"
  plutil -lint "$bundle/Contents/Info.plist"
  codesign --force --sign "$identity" --timestamp=none --identifier org.infinitedesk.tests.desktop-acceptance "$bundle"
  codesign --verify --strict "$bundle"
  printf '%s\n' "$identity" > "$build/build-identity"
  printf '%s\n' "$fingerprint" > "$build/build-fingerprint"
else
  echo 'Reusing unchanged acceptance bundle.'
fi
codesign --verify --strict "$bundle"
sh -n "$here/driver-command.sh"
node --check "$here/run.mjs"
if [ "$1" = --check ]; then
  node --check "$here/pan.mjs"
  node --check "$here/camera.mjs"
  node --check "$here/camera-lifecycle.mjs"
  node --check "$here/overview.mjs"
  node --check "$here/geometry.mjs"
  node --test "$here/geometry.test.mjs"
  printf 'Acceptance bundle verified: %s\nNo GUI or permissions check was performed.\n' "$bundle"
  exit 0
fi
exec node "$here/run.mjs" "$here/driver-command.sh"
