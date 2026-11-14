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
LaunchServices using `open -W -n -g -j`. The executable is never invoked directly
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

`--check` builds and ad-hoc signs the dedicated Swift 6 app with warnings treated
as errors, verifies the bundle signature, and parses the scripts. An unchanged
build is reused, preserving its signature. It opens no windows and does not
check permissions. A successful check is not a successful live acceptance run.
`--run` never compiles or signs the app: it refuses a missing or stale build and
requires an explicit `--check` first. It first runs the permission
preflight. During a live run, leave the test's Chrome windows alone; ordinary
typing or changing windows makes the result fail. Run only one graphical test
at a time.

`driver-command.sh` creates a private temporary directory for each invocation,
launches the app without foregrounding it, and waits for exit. The app atomically
writes a versioned JSON envelope containing the command result and its actual
exit code. The wrapper validates this envelope, prints the result, and propagates
0, 1, or 77. It does not treat `open`'s own success as the app's success. Command
scratch files are removed after reading; the Chrome report directory is retained.

The driver permits native operations only against a live `com.google.Chrome`
PID. The orchestrator independently verifies that this PID is the exact child
process it launched with a temporary user-data directory. Before every input
operation it verifies that the expected disposable native window is frontmost.
Typing uses PID-targeted Unicode key events. Global shortcut events are emitted
only while that expected fixture window is frontmost:

| Operation | Shortcut |
| --- | --- |
| Register foreground window | Control + Option + Command + W |
| Previous registered window | Control + Option + Command + Left |
| Next registered window | Control + Option + Command + Right |

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

This harness does not inject a delayed backend completion. That cancellation
case must be assessed from the backend test results separately. Frame readbacks
verify unchanged geometry; zero position/size writes are not counted by this
harness. Consult adapter test results as separate evidence. Finder and Dock ordinary input remain a manual acceptance
step: record their observed behavior separately, without modifying user files.
