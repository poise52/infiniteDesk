#!/bin/sh
set -eu
[ "$#" -ge 1 ] || { echo 'Usage: driver-command.sh preflight | finder-snapshot | snapshot PID | focus PID WINDOW | shortcut PID WINDOW COMMAND | type PID WINDOW TOKEN | gesture PID WINDOW JSON' >&2; exit 2; }
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../../.." && pwd)
bundle="$root/target/desktop-acceptance/InfiniteDesk Acceptance.app"
[ -x "$bundle/Contents/MacOS/Driver" ] || { echo 'Build acceptance first: run.sh --check' >&2; exit 1; }
identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$bundle/Contents/Info.plist")
[ "$identifier" = org.infinitedesk.tests.desktop-acceptance ] || { echo 'Unexpected acceptance bundle identifier' >&2; exit 1; }
/usr/bin/codesign --verify --strict "$bundle"
operation_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinitedesk-driver-command.XXXXXXXX")
trap 'rm -rf "$operation_dir"' 0
trap 'exit 130' INT
trap 'exit 143' TERM HUP
python3 - "$bundle" "$operation_dir" "$@" <<'PY'
import json
import pathlib
import subprocess
import sys
import time

bundle, scratch = sys.argv[1], pathlib.Path(sys.argv[2])
result_path = scratch / "result.json"
launcher = None
try:
    with (scratch / "open.stdout").open("w") as stdout, (scratch / "open.stderr").open("w") as stderr:
        launcher = subprocess.Popen([
            "/usr/bin/open", "-n", "-g", "-j", "--stdout", str(scratch / "app.stdout"),
            "--stderr", str(scratch / "app.stderr"), bundle,
            "--args", "--result", str(result_path), *sys.argv[3:]
        ], stdout=stdout, stderr=stderr)
    deadline = time.monotonic() + 8
    while not result_path.exists():
        if time.monotonic() >= deadline:
            raise TimeoutError(f"No atomic command result within 8 seconds; open status={launcher.poll()}. Outcome is unknown; the action was not retried")
        time.sleep(0.025)
    envelope = json.loads(result_path.read_text())
    if not isinstance(envelope, dict) or envelope.get("protocolVersion") != 1 or type(envelope.get("exitCode")) is not int:
        raise ValueError("invalid result protocol")
    code = envelope["exitCode"]
    if code not in (0, 1, 77) or not isinstance(envelope.get("result"), dict):
        raise ValueError("invalid command result")
except (OSError, ValueError, TypeError, TimeoutError) as error:
    print(f"Acceptance app did not return a valid status: {error}", file=sys.stderr)
    for name in ("open.stderr", "app.stderr"):
        path = scratch / name
        if path.exists():
            print(f"{name}: {path.read_text()}", file=sys.stderr)
    sys.exit(1)
finally:
    if launcher is not None:
        try:
            launcher.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            launcher.terminate()
            try:
                launcher.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                launcher.kill()
                launcher.wait()
print(json.dumps(envelope["result"], separators=(",", ":")))
sys.exit(code)
PY
