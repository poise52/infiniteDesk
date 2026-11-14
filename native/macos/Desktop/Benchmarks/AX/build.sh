#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../../../.." && pwd)
source_root=$root
[ "$#" -le 2 ] || { echo 'Usage: build.sh [source-root] [cache-tag]' >&2; exit 2; }
if [ "$#" -ge 1 ]; then source_root=$(CDPATH= cd -- "$1" && pwd); fi
tag=${2:-current}
case "$tag" in ''|*[!a-zA-Z0-9_-]*) echo 'Invalid cache tag' >&2; exit 2 ;; esac
batch_experiment=${INFINITEDESK_AX_BATCH_EXPERIMENT:-0}
case "$batch_experiment" in 0|1) ;; *) echo 'INFINITEDESK_AX_BATCH_EXPERIMENT must be 0 or 1' >&2; exit 2 ;; esac
build="$root/target/desktop-ax-benchmark"
cache="$build/cache/$tag"
bundle="$build/InfiniteDesk AX Benchmark.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$build/module-cache" "$cache"
python3 - "$source_root" "$here" "$cache/source-next.json" <<'PYTHON'
import hashlib, json, pathlib, sys
source, harness, output = map(pathlib.Path, sys.argv[1:])
files = [source / "native/macos/Desktop" / name for name in (
    "DesktopWindows.swift", "DesktopObservation.swift", "DesktopCamera.swift",
    "DesktopCameraJournal.swift", "DesktopCameraRecovery.swift")]
files.append(harness / "main.swift")
output.write_text(json.dumps({path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                              for path in files}, sort_keys=True, indent=2) + "\n")
PYTHON
python3 - "$batch_experiment" "$cache/build-configuration-next.json" <<'PYTHON'
import json, pathlib, sys
experiment = sys.argv[1] == "1"
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "batchExperiment": experiment,
    "readStrategy": "bulk-experiment" if experiment else "scalar",
    "swiftDefines": ["DESKTOP_AX_BATCH_EXPERIMENT"] if experiment else [],
}, sort_keys=True, indent=2) + "\n")
PYTHON
xcrun swiftc --version > "$cache/toolchain-next.txt" 2>&1
fingerprint=$(shasum -a 256 "$cache/source-next.json" "$cache/build-configuration-next.json" "$cache/toolchain-next.txt" "$here/build.sh" | shasum -a 256 | awk '{print $1}')
previous=''
if [ -r "$cache/fingerprint" ]; then previous=$(cat "$cache/fingerprint"); fi
if [ "$fingerprint" != "$previous" ] || [ ! -x "$cache/AXBenchmark" ]; then
  set --
  if [ "$batch_experiment" = 1 ]; then set -- -D DESKTOP_AX_BATCH_EXPERIMENT; fi
  xcrun swiftc "$@" -O -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macosx15.0" \
    -module-cache-path "$build/module-cache" \
    "$source_root/native/macos/Desktop/DesktopWindows.swift" \
    "$source_root/native/macos/Desktop/DesktopObservation.swift" \
    "$source_root/native/macos/Desktop/DesktopCamera.swift" \
    "$source_root/native/macos/Desktop/DesktopCameraJournal.swift" \
    "$source_root/native/macos/Desktop/DesktopCameraRecovery.swift" \
    "$here/main.swift" -o "$cache/AXBenchmark-next"
  mv "$cache/AXBenchmark-next" "$cache/AXBenchmark"
  mv "$cache/source-next.json" "$cache/source-fingerprints.json"
  mv "$cache/build-configuration-next.json" "$cache/build-configuration.json"
  printf '%s\n' "$fingerprint" > "$cache/fingerprint"
else
  rm "$cache/source-next.json" "$cache/build-configuration-next.json"
  echo "Reusing matching compiled $tag executable."
fi
if [ "${INFINITEDESK_BENCH_STAGE:-1}" = 0 ]; then
  "$cache/AXBenchmark" --self-test
  printf 'Compiled cache ready: %s\nStable app was not changed.\n' "$cache"
  exit 0
fi
cp "$cache/AXBenchmark" "$bundle/Contents/MacOS/AXBenchmark"
cp "$cache/source-fingerprints.json" "$bundle/Contents/Resources/source-fingerprints.json"
cp "$cache/build-configuration.json" "$bundle/Contents/Resources/build-configuration.json"
cp "$here/Info.plist" "$bundle/Contents/Info.plist"
codesign --force --sign "${INFINITEDESK_SIGN_IDENTITY:--}" --timestamp=none --identifier org.infinitedesk.tests.ax-benchmark "$bundle"
codesign --verify --strict "$bundle"
"$bundle/Contents/MacOS/AXBenchmark" --self-test
printf 'Staged production sources from %s\n%s\nNo GUI launched; no permission check performed.\n' "$source_root" "$bundle"
