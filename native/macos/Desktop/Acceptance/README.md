# Desktop manager acceptance

This opt-in graphical integration test exercises the packaged desktop manager
through its real global shortcuts. It uses two original Google Chrome windows
in a newly created disposable profile. It never connects to an existing Chrome
DevTools endpoint, opens the user's profile, edits permission settings, or uses
the old InfiniteDesk board.

Requirements: macOS 15 or newer, Google Chrome in `/Applications`, Node.js 22 or
newer, Python 3, the Xcode command line tools, and an already running fresh desktop manager
with **zero registered windows**. Quit and reopen the manager before each run.
The manager needs its normal Accessibility grant. The separate **InfiniteDesk
Acceptance** app also needs Accessibility and event-posting access. Neither app asks
for or grants permissions. A missing host grant produces **SKIP**, exit code 77,
before Chrome launches or any key is sent. Screen Recording is not used.

The stable test app lives at `target/desktop-acceptance/InfiniteDesk Acceptance.app`
and has the independent bundle ID `org.infinitedesk.tests.desktop-acceptance`.
Its identity does not reuse the product's permission grant. There is no need to
grant Terminal, Codex, Node, or Python access for this harness.

These are two separate checks inside the acceptance app:
`AXIsProcessTrusted()` must be true for AX reads/actions, and
`CGPreflightPostEventAccess()` must be true for synthesized keys. The driver does
not install a listening event tap, request Input Monitoring, send Apple Events,
or request Automation access. The desktop manager has its own Accessibility
identity and its grant does not establish that the acceptance app can control windows.

Every command, including preflight, starts the dedicated app through macOS
LaunchServices using `open -n -g -j`. The executable is never invoked directly
by Node or a shell. This avoids attributing a raw command-line helper's access
to Terminal or another development host. Reports include `launchContext`: the
app's path, bundle ID, public parent-process paths, and selected environment
hints. The harness does not read or edit the TCC database.

From the repository root:

```sh
native/macos/Desktop/Acceptance/run.sh --check
# Check only the app's existing grant, without Chrome or permission prompts:
native/macos/Desktop/Acceptance/driver-command.sh preflight
# Open the freshly built desktop-manager app, then:
native/macos/Desktop/Acceptance/run.sh --run
```

`--check` builds and signs the dedicated Swift 6 app with warnings treated
as errors, verifies the bundle signature, and parses the scripts. An unchanged
build is reused, preserving its signature. It opens no windows and does not
check permissions. A successful check is not a successful live acceptance run.
`--run` never compiles or signs the app: it refuses a missing or stale build and
requires an explicit `--check` first. It first runs the permission
preflight. During a live run, leave the test's Chrome windows alone; ordinary
typing or changing windows makes the result fail. Run only one graphical test
at a time.

Signing uses the same optional `INFINITEDESK_SIGN_IDENTITY` setting as the product
build. The first build defaults to ad-hoc (`-`); later invocations reuse the
recorded identity unless the variable explicitly selects another. The build
fingerprint includes the sources and signing identity. For a local developer
certificate, build once before reviewing the app's Accessibility grant:

```sh
INFINITEDESK_SIGN_IDENTITY=781FB0138D37428A049A4DADFF79D95F2836FA87 \
  native/macos/Desktop/Acceptance/run.sh --check
native/macos/Desktop/Acceptance/run.sh --run
```

The second command reuses that exact built bundle and signature without needing
the variable again. An explicit different identity or changed source makes
`--run` refuse the stale build; it never silently recompiles or resigns.

`driver-command.sh` creates a private temporary directory for each invocation,
launches the app without foregrounding it, and waits up to eight seconds for its
atomic result. It does not use `open -W`, whose exit observer can race with a
short-lived app. The app atomically
writes a versioned JSON envelope containing the command result and its actual
exit code. The wrapper validates this envelope, prints the result, and propagates
0, 1, or 77. It does not treat `open`'s own success as the app's success. Command
results take precedence even if the launcher exits with an error. Missing or
invalid results retain launcher/app diagnostics and never cause an action retry.
scratch files are removed after reading; the Chrome report directory is retained.

The driver permits native operations only against a live `com.google.Chrome`
PID. The orchestrator independently verifies that this PID is the exact child
process it launched with a temporary user-data directory. Before every input
operation it verifies that the expected disposable native window is frontmost.
Typing uses PID-targeted Unicode key events. Global shortcut events are emitted
only while that expected fixture window is frontmost.

Shortcut events use an isolated private event source and retain only the
constructor's inherent Fn/NumPad flags alongside the requested modifiers. This
preserves native arrow-key classification without importing unrelated physical
or previously synthesized modifier state.

| Operation | Shortcut |
| --- | --- |
| Register foreground window | Control + Option + Command + W |
| Previous registered window | Control + Option + Command + Left |
| Next registered window | Control + Option + Command + Right |
| Workspace overview | Control + Option + Command + O |

The run records real AX frames and Core Graphics window IDs, types independent
tokens into original A and B, and registers both. It cycles A → B → A through
the shortcuts, verifies native focus and DOM input-event readbacks, and checks
that both frames and identities remain unchanged. It then gives both pages the
same title and repeats B → A. Finally it closes registered B, opens an unregistered
replacement with the same title and bounds, and verifies that selecting the dead
registration leaves input in A and does not edit or focus the replacement.
The helper raises windows only during setup and when restoring A before the
closed-target negative case; all tested cycles use the manager shortcut.
Cycle typing never calls a DOM focus operation, native raise, or app activation.
It first records a native focus snapshot and asserts that the destination page
already has focus with its target field active. The PID-targeted typing helper
independently checks native focus again before posting. These pre-input samples
are retained in `inputEvidence`, so typing cannot make a failed switch pass.

Chrome DevTools is enabled on a random **127.0.0.1** port for this disposable
process only. It supplies page values, input counters, and setup/cleanup; it does
not supply the focus operation being tested. The fixture loads no external
content. Chrome's `--disable-background-networking` reduces background traffic
and is not a network isolation guarantee.
The harness verifies the exact spawned PID's listening socket with `lsof`,
rejects wildcard or non-loopback bindings, and checks the DevTools browser PID
before any target mutations. Protocol cleanup is sent only after this identity
check. Fallback termination targets only the child handle created by this run;
there is no process-name kill or automatic profile deletion.

Every live attempt prints a temporary evidence directory containing `report.json`,
`chrome.log`, and the disposable `profile/`. A permission skip writes its own
`report.json` with the missing prerequisites and confirms that no fixtures or
manager actions were started. `PASS` means the listed live cases passed; `FAIL`
includes the error and any completed checkpoints. Both paths close only the
Chrome process created by this run and retain the evidence. Remove the printed
directory after reviewing it and confirming its Chrome process has exited.
Each listed live case starts as `NOT_RUN` and changes to `PASS` only at its
completed checkpoint. The setup-input checkpoint does not by itself establish
that the manager registered the windows; subsequent successful shortcuts supply
that behavior evidence.

Schema 2 reports separate `nativeFocusCases`/`nativeFocusStatus` from
`inputCases`/`inputStatus`. A probe-token delivery failure is recorded and does
not stop registering the second window or exercising subsequent shortcuts.
Each native cycle is assessed before any trial characters are posted. A native
focus/geometry failure still stops the run because further input would be
unsafe. The overall result remains `FAIL` when any input probe fails, even when
all independent native focus cases pass. Combined `cases` require both results.

Every input attempt records both pages before and after: native focus/frames,
target and decoy values, DOM readouts/counters, active field and selection/caret.
The fixture also records trusted keyboard, beforeinput, input and focus events,
including their modifier flags. Fatal errors save a final `failureEvidence`
snapshot before Chrome cleanup. Failed delivery is never repaired with CDP
insertion or a focus change, and the next probe uses its own observed baseline
instead of a value assumed to have been typed successfully.

This harness does not inject a delayed backend completion. That cancellation
case must be assessed from the backend test results separately. Frame readbacks
verify unchanged geometry; zero position/size writes are not counted by this
harness. Consult adapter test results as separate evidence. Finder and Dock ordinary input remain a manual acceptance
step: record their observed behavior separately, without modifying user files.

## Opt-in stage 2: real desktop geometry

Stage 1 remains the default. Stage 2 runs only when the same explicit absolute
`INFINITEDESK_TEST_STATE_PATH` is passed to the fresh desktop manager and this
harness. The manager must have written that JSON snapshot before acceptance
starts. The harness only reads this path and never creates, edits or removes it.
For example, from the repository root:

```sh
state_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinitedesk-stage2.XXXXXXXX")
state_path="$state_dir/model.json"
open -n -g --env "INFINITEDESK_TEST_STATE_PATH=$state_path" target/InfiniteDesk.app
# Wait for the fresh manager to write model.json, then:
INFINITEDESK_TEST_STATE_PATH="$state_path" native/macos/Desktop/Acceptance/run.sh --run
```

The snapshot contract is `{windows:[{id,pid,title,originalFrame,worldFrame,availability}],focusedID?}`.
IDs are model UUIDs; frames use global AX coordinates in points; availability
is `available`, `unavailable` or `closed`. Original A/B UUIDs are bound through
their PID and original registration frames, then retained even after their
titles become identical. Geometry cases require this hook; DOM/CDP readbacks
alone are not accepted as evidence of the manager's world-frame state.

The test discovers the screen's usable work area through the disposable page's
`screen.avail*` values. It places A and B in distinct, vertically separated
positions, with B around 40% of the display width so its titlebar is exposed
while A is foreground. Setup raises B and then A so the two owned windows are
adjacent in z-order above unrelated windows; the tested external click still
starts with A in front. The fast drag moves B into the right half. Resize and
repeat-drag deltas keep the complete window and mouse paths inside the work area.
The current 3440×1318-point work area and a 1280×750-point laptop work area have
pure planning tests; smaller unsupported layouts fail before a gesture.

Distinct stage-2 cases record:

- The registered original frames, immutable UUIDs and originalFrame values.
- An external real titlebar click on B, independent of manager shortcuts, and
  the resulting native focus plus model focusedID.
- A fast titlebar drag from the left half to the right, a real bottom-right
  corner resize, and a second titlebar drag.
- Two additional short titlebar drags issued consecutively without a model
  settling wait between them; their combined final AX/model frame is checked.
  The preferred deltas are (-64,-37) and (-54,-32) points to clear ordinary
  snapping distances. Smaller work areas reduce them within the safe margin
  beside A, keeping both components at least 20 points.
- A separate corner shrink toward 160×120 points. A minimum-size constraint is
  `PASS` only if Chrome actually changes size but applies larger dimensions.
  Otherwise this optional observation is `NOT_OBSERVED` or `INCONCLUSIVE`.
- Destroyed B disappearing from the model or becoming unavailable/closed, and
  a same-title replacement remaining unregistered.

The driver uses actual mouse-down/drag/up events. Before mouse-down it checks
the exact disposable PID/CG ID, first layer-0 CG hit, exact retained AXWindow hit, original
frame, safe display bounds, button/modifier state and foreground application.
A guard can wait up to 600ms for the original input/foreground conditions to
clear, without activating an app or clearing user input. Its raw HID/combined
flags, button states and foreground PID samples are saved on success or refusal.
Failures release an already posted mouse-down without retrying the gesture.
Titlebar and corner contacts are chosen from safe candidates. The AX hit may be
the window itself or resolve through its window/parent attributes; its PID and
window CF identity must match the retained target. A higher-layer noninteractive
overlay, such as the Dock's full-screen CG surface, does not override this exact
AX evidence. Candidate diagnostics retain CG IDs/PIDs/layers and AX role/match
only, without window titles or contents.

After mouse-up, independent AX reads must remain stable for at least three
samples and one second while worldFrame converges to the actual frame. A's
native frame and both pages' values/counters must stay unchanged. The already
confirmed model focusedID must remain B during move/resize. Existing visible
ordinary Finder windows are checked by PID/CG ID/frame only; no Finder titles
or file paths are read. If none exists, only the Finder geometry check is
`SKIP`; Finder is not opened.

Cursor deltas are commands, not exact frame predictions: WindowServer can snap
or scale a real gesture. Drag requires meaningful motion in the requested
direction with unchanged size. Resize requires size changes in the requested
directions with unchanged origin; a click requires an unchanged frame. No-op or
opposite-direction core gestures fail. Both rapid drags use X/Y motion; an
independent AX sample supplies the second drag's guarded starting frame without
waiting for model settling. Each segment and the final result are retained.
The strict one-point comparison is between model worldFrame and actual AX frame.
After the initial native settling grace, a stable post-release frame becomes an
anchor. The test then watches for significant delayed displacement, including
snapback that still leaves the window on the requested side. Failed native
focus/foreground samples are saved before assertions. Stage 2 also requires an
actually empty initial model and blocks shortcuts if any unrelated PID becomes
registered; owned closed records remain valid for the destruction test.

`geometry.status` covers the required geometry/model cases, separately from
native focus and input results. Minimum-size and Finder observations retain
their separate statuses. A requested stage-2 failure makes the run fail. No live
stage-2 result is implied by `--check`, which compiles/signs the driver and runs
only the pure model and work-area guard tests.

## Stage 3: moving between desktop pages

The camera test runs on one display and one ordinary macOS Space. It registers
two windows with identical titles in the disposable Chrome profile. It moves B
one page right, verifies a manual drag at a nonzero camera origin and types into
both originals after switching. It checks the native Chrome window state, the
on-screen Core Graphics window IDs, world coordinates, and a separate recovery
journal. The Finder window, when present, must keep its native bounds.

Run each mode with a fresh manager and a fresh directory. Quit the development
manager normally before starting. Keep the mouse and keyboard free while the
two fixture windows are open. The normal product grant and the temporary driver
grant are the same as for stage 2.

```sh
camera_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinitedesk-camera.XXXXXXXX")
camera_dir=$(cd "$camera_dir" && pwd -P)
export INFINITEDESK_TEST_STATE_PATH="$camera_dir/model.json"
export INFINITEDESK_TEST_CAMERA_JOURNAL_PATH="$camera_dir/journal.json"
export INFINITEDESK_TEST_SESSION=$(uuidgen)
open -n -g --env "INFINITEDESK_TEST_STATE_PATH=$INFINITEDESK_TEST_STATE_PATH" \
  --env "INFINITEDESK_TEST_CAMERA_JOURNAL_PATH=$INFINITEDESK_TEST_CAMERA_JOURNAL_PATH" \
  --env "INFINITEDESK_TEST_SESSION=$INFINITEDESK_TEST_SESSION" target/InfiniteDesk.app
# Once model.json appears, select quit or crash for this fresh test session.
INFINITEDESK_TEST_CAMERA_MODE=quit native/macos/Desktop/Acceptance/run.sh --run
```

In `quit` mode, the signed driver asks the tested app to quit. Both original
windows must reappear and the journal must clear. In `crash` mode, it interrupts
only the session-matched development manager and relaunches the same bundle.
The restarted manager must report the pending window, keep both registrations
unbound, and leave the parked original alone. The test restores the identified
disposable Chrome window through its own browser and verifies both frames.
The recovery record remains available for manual acknowledgement. The test
uses a private journal for each mode. Its report records the individual checks
and the state observed independently of the manager.

## Continuous horizontal pan

Using the same fresh-manager procedure, set `INFINITEDESK_TEST_CAMERA_MODE=pan`.
The driver sends ⌥⌘ drags, reverses direction, and samples the
original Chrome window's horizontal position from WindowServer while it moves.
The test compares the two native window frames with the manager's logical
coordinates after each gesture, including partial visibility, parking and
restoration. It types in the original, drags its title bar, verifies ordinary
scrolling from the browser’s trusted DOM input and scroll position, pauses the manager,
checks both restored frames and verifies that the recovery journal is empty.

`camera.metrics` records successful native work and delivery times in
milliseconds. `camera.motion.observedCGIntervals` describes the intervals
between changed positions observed by a polling client. Display presentation
times require a separate measurement. For a discrete comparison on the same
build, start a fresh manager in `quit` mode and set
`INFINITEDESK_TEST_PAGE_ROUNDTRIPS=4` to add eight verified page switches.

## Workspace overview

Use the same isolated fresh-manager procedure with
`INFINITEDESK_TEST_CAMERA_MODE=overview`. Build the product and run acceptance
`--check` before reviewing the dedicated driver's existing grant. This mode
requires the opt-in model export to include
`overview: {visible,isKey,windowNumber?,selectedID?}`. It opens no permission prompts.

```sh
INFINITEDESK_TEST_CAMERA_MODE=overview native/macos/Desktop/Acceptance/run.sh --run
```

The harness registers original A then B, gives both the identical title, and
retains their model UUIDs and independent native CG identities. From focused B
it opens overview and sends Escape. Both native frames, native/model focus,
camera state, world geometry, and input values must stay unchanged. It then
moves B one page right, verifies that A is parked, opens overview, selects A
with Tab, and presses Enter. It verifies the exact original A at native 1:1 and
types a token into its already focused field. A second overview uses Shift-Tab
to select B and repeats the native focus/input proof. Selection may move the
camera only far enough to reveal the chosen window; the test compares native
bounds with world coordinates minus the actual camera origin. It does not
assume that selection snaps to a page origin.

Escape, Tab, Shift-Tab, and Enter are posted only to the manager PID. Before
each key the signed driver verifies the exact current product bundle,
process birth identity, session UUID, opt-in paths, and snapshot ownership.
The snapshot must identify the visible key panel and expected selected UUID.
An independent on-screen CG record must match that panel's exact window number
and manager owner PID. Chrome must remain foreground with the expected original
AX window focused. A failed guard sends no key. The driver never activates the
manager or posts these plain keys globally.

`camera.overview` retains checkpoints and guarded key receipts. Each return
checks original sizes, unchanged world frames, CG visibility, AX minimization,
Chrome's independent native window state, and existing Finder bounds. Finally
Pause must restore both original frames and clear the isolated recovery journal.
`--check` compiles and signs the driver and parses the overview script; only
`--run` establishes a live overview result.
