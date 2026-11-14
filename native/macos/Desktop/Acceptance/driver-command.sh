#!/bin/sh
set -eu
[ "$#" -ge 1 ] || { echo 'Usage: driver-command.sh preflight | snapshot PID | focus PID WINDOW | shortcut PID WINDOW COMMAND | type PID WINDOW TOKEN' >&2; exit 2; }
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
if ! /usr/bin/open -W -n -g -j --stdout "$operation_dir/app.stdout" --stderr "$operation_dir/app.stderr" \
  "$bundle" --args --result "$operation_dir/result.json" "$@"; then
  echo 'LaunchServices could not complete the acceptance command' >&2
  exit 1
fi
python3 - "$operation_dir/result.json" "$operation_dir/app.stderr" <<'PY'
import json
import pathlib
import sys

try:
    envelope = json.loads(pathlib.Path(sys.argv[1]).read_text())
    if envelope.get("protocolVersion") != 1 or type(envelope.get("exitCode")) is not int:
        raise ValueError("invalid result protocol")
    code = envelope["exitCode"]
    if code not in (0, 1, 77) or not isinstance(envelope.get("result"), dict):
        raise ValueError("invalid command result")
except (OSError, ValueError, TypeError) as error:
    print(f"Acceptance app did not return a valid status: {error}", file=sys.stderr)
    stderr = pathlib.Path(sys.argv[2])
    if stderr.exists():
        print(stderr.read_text(), file=sys.stderr)
    sys.exit(1)
print(json.dumps(envelope["result"], separators=(",", ":")))
sys.exit(code)
PY
