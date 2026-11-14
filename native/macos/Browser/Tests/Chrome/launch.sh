#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
chrome='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

if [ "${1-}" = --check ]; then
  test -x "$chrome"
  test -r "$here/a.html" && test -r "$here/b.html"
  echo 'Chrome executable and both fixture pages are available.'
  exit 0
fi
if [ "${1-}" != --launch ] || [ "$#" -ne 1 ]; then
  echo "Usage: $0 --check | --launch" >&2
  exit 2
fi
[ -x "$chrome" ] || { echo "Chrome not found: $chrome" >&2; exit 1; }
profile=$(mktemp -d "${TMPDIR:-/tmp}/infinitedesk-chrome.XXXXXXXX")
a=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).as_uri())' "$here/a.html")
b=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).as_uri())' "$here/b.html")
printf 'Disposable Chrome profile: %s\nChrome logs: %s/first.log and %s/second.log\n' "$profile" "$profile" "$profile"
"$chrome" --user-data-dir="$profile" --no-first-run --no-default-browser-check --disable-background-networking --new-window "$a" >"$profile/first.log" 2>&1 &
first=$!

# Wait for the isolated profile's singleton before issuing the second request.
ready=0
for _ in $(seq 1 30); do
  if ! kill -0 "$first" 2>/dev/null; then
    if wait "$first"; then status=0; else status=$?; fi
    echo "First Chrome process exited before readiness (status $status); inspect $profile/first.log." >&2
    exit 1
  fi
  if [ -L "$profile/SingletonLock" ] || [ -e "$profile/SingletonLock" ]; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "Chrome singleton did not become ready; inspect $profile/first.log. Close the fixture Chrome process to release the launcher." >&2
  wait "$first" || :
  exit 1
fi

"$chrome" --user-data-dir="$profile" --no-first-run --no-default-browser-check --disable-background-networking --new-window "$b" >"$profile/second.log" 2>&1 &
second=$!
request_done=0
for _ in $(seq 1 15); do
  if ! kill -0 "$second" 2>/dev/null; then
    if wait "$second"; then
      echo 'Second Chrome request returned status 0; visually verify both separate windows.'
    else
      status=$?
      echo "Second Chrome request failed (status $status); inspect $profile/second.log. Close the fixture Chrome process to release the launcher." >&2
      wait "$first" || :
      exit 1
    fi
    request_done=1
    break
  fi
  if ! kill -0 "$first" 2>/dev/null; then
    if wait "$first"; then status=0; else status=$?; fi
    echo "First Chrome process exited during the second request (status $status); inspect $profile/first.log." >&2
    echo "Waiting for the second request to exit; inspect $profile/second.log." >&2
    wait "$second" || :
    exit 1
  fi
  sleep 1
done
if [ "$request_done" -ne 1 ]; then
  echo "Second Chrome request did not exit within 15 seconds; inspect $profile/second.log and verify the windows manually." >&2
fi
printf 'Expected window titles: InfiniteDesk Chrome A; InfiniteDesk Chrome B\nLauncher remains active until the first Chrome process exits.\n'
if wait "$first"; then
  if [ "$request_done" -ne 1 ]; then wait "$second" || exit 1; fi
  echo 'First Chrome process exited successfully.'
else
  status=$?
  echo "First Chrome process failed (status $status); inspect $profile/first.log." >&2
  if [ "$request_done" -ne 1 ]; then wait "$second" || :; fi
  exit "$status"
fi
