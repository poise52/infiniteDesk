# InfiniteDesk

> [!WARNING]
> **Do not download or install InfiniteDesk.** The project is unfinished. The build instructions below are for development and testing only.

InfiniteDesk is a macOS menu bar app for registering and focusing real application windows. Registration reads the focused window where it is. You can then switch between registered windows, including two windows belonging to the same app. The development build also has horizontal workspace panning and page shortcuts at 1:1 scale, Pause/Restore and an interrupted-session recovery journal. Registrations last for the current session. The workspace overview shows registered windows at their world positions and lets you return to a selected original.

## Build and try the desktop manager

Build on an Apple Silicon Mac with Xcode or Apple Command Line Tools that support Swift 6. The minimum deployment target is macOS 15.

```sh
./scripts/build-macos-app.sh
open target/InfiniteDesk.app
```

Open the InfiniteDesk icon in the menu bar and grant Accessibility access when requested. For local development, set `INFINITEDESK_SIGN_IDENTITY` to your Apple Development signing identity before building if you want a consistent signing identity across builds. The default is an ad-hoc signature, so macOS may request permission again after rebuilding.

1. Focus a window and press **⌃⌥⌘W** to register it. Repeat with a second window.
2. Press **⌃⌥⌘←** or **⌃⌥⌘→** to focus the previous or next registered window. Type directly in the original application.
3. Drag a registered window by its title bar, or resize it by an edge. Release the mouse and open the InfiniteDesk menu. The window's row shows its workspace position and size in macOS points. Page changes preserve these workspace coordinates.
4. A checkmark identifies the focused registered window. Choose a row to focus that window. A closed window keeps its last known bounds until you forget it. The menu reports when an application cannot send the notifications used for tracking.

Press **⌃⌥⌘O** to see the registered windows on a map. The dashed outline shows the current viewport. Scroll or pinch to zoom around the pointer, press **F** to fit the workspace, or use **Tab** and the arrow keys to select a window. **Enter** or a click opens the selected original at 1:1. If it is offscreen, the camera moves just far enough to show it. **Escape** closes the map and leaves the desktop where it was. The map uses window bounds, titles and app icons and requires no screen capture.

For the experimental page controls, use one display and one ordinary macOS Space. Fullscreen windows and windows on other Spaces are outside this stage's scope. Managed windows on other pages are minimized through macOS and restored when you return. The menu reports the current page, camera origin, paused state and operation failures.

| Shortcut | Action |
|---|---|
| **⌃⌥⌘W** | Register the focused window without moving it. |
| **⌃⌥⌘← / →** | Focus the previous/next registered window; reveal its page when necessary. |
| **⌃⌥⌘N** | Move the focused registered window one page right and follow it. |
| **⌃⌥⌘O** | Open or dismiss the workspace overview. |
| **⌃⌥⌘[ / ]** | Move the camera to the previous/next workspace page. |
| **⌥⌘ + left drag** | Pan horizontally; the workspace follows the pointer. Release, reposition the pointer and drag again to continue. |
| **⌃⌥⌘ + scroll** | Pan with a mouse wheel or trackpad; horizontal scrolling takes precedence, vertical scrolling is a fallback. |
| **⌃⌥⌘P** | Pause and restore managed windows; press again to resume the workspace. |

The keyboard commands are also available from the menu. If macOS cannot register a shortcut or install the pan event tap, the menu reports the failure; resolve the conflict and choose **Retry global input**. Bracket shortcuts use the physical US bracket keys.

To try continuous pan, register two windows, hold **⌥⌘ before pressing the left mouse button**, then drag horizontally. This gesture works over an application's content or title bar and does not click or drag the underlying window. Drag right to bring workspace content right; drag left to explore further right. Release the button to finish, then type or scroll in the original app normally. Adding the chord after a normal mouse-down preserves the application's drag. Releasing the chord during pan stops movement and consumes the rest of that button gesture. **⌃⌥⌘ + scroll** follows the macOS scrolling direction; the manager multiplies each delivered wheel unit by 24 points and uses trackpad point deltas directly. Mouse utilities can change the units macOS delivers. Keep the chord held for trackpad momentum; releasing it stops pan and absorbs the remaining momentum of that gesture.

Pan requires Accessibility, a running workspace and at least one registered window. It leaves typing in the selected app when panning across visible windows. Screen Recording and Input Monitoring permissions are not required by the manager. Ordinary clicks and unmodified scrolling remain with the active application. The public session event tap filters only these dedicated gestures. The manager checks Accessibility at gesture start and when the menu opens. Granting access again and choosing **Retry global input** reinstalls it. No input polling or idle animation timer runs. A timeout cancels the current pan and asks you to release and restart the gesture; the menu also reports a tap disabled by the system.

**Pause and restore windows** makes managed windows accessible again and suspends workspace placement. If restoration fails, **⌃⌥⌘P** retries **Restore managed windows** before allowing Resume. **Restore windows and quit InfiniteDesk** restores them before exiting; a failed restore keeps the manager running and reports the failure. Force Quit cannot run this restore. After an interrupted session, choose **Recover interrupted session…**, restore the listed windows through their application's Window menu or Dock icon, then explicitly acknowledge that you restored them. Recovery does not guess window identity from a title or PID.

On macOS 27.0.1, the earlier local GUI tests verified page switching and immediate typing in two Chrome 156 windows with identical titles on one display. The off-page original disappeared from the on-screen window list, and the visible Finder window kept its bounds. Both Pause and normal Quit released the parked original. After a forced termination, the restarted manager kept the journal available for manual recovery. A separate live pan test moved both original windows, reversed direction, moved A to x = −32 pt, then parked and restored it. B kept keyboard focus when A returned, and the next typed token reached B’s original text field. Ordinary wheel input scrolled the browser. Pause restored A and kept B’s most recent manual placement.

On this Mac, 230 continuous camera batches over two Chrome windows took 19.3 ms at p50, 38.0 ms at p95 and 40.0 ms at p99 on the AX worker. Independent WindowServer polling observed changing positions at p99 intervals of 41–42 ms across two drags. Neither measurement times display presentation.

The [native AX benchmark](native/macos/Desktop/Benchmarks/AX/README.md) separately moved 2, 5 and 10 real AppKit windows. The baseline's individual attribute reads took 37, 77 and 137 ms at p99 per movement batch; experimental grouped reads took 36, 68 and 149 ms. Each figure pools two runs of 40 batches; at this sample size p99 is the slowest observation. The normal build keeps individual reads. In a separate run with the restoration fix and grouped reads, minimizing all 10 windows at the workspace edge took 6.16 s and restoring them took 6.34 s (one measured batch each). Crossing the edge with many windows is still visibly slow.

In the live overview test, Escape preserved both original frames, camera position and Chrome focus. Selecting parked originals with Tab or Shift-Tab and pressing Enter delivered the next typed token to the chosen window, even though both titles matched. Pause then restored both originals and retained B’s focus.

Run the desktop checks without opening windows or granting Accessibility access:

```sh
native/macos/Desktop/Tests/run.sh
native/macos/Desktop/Acceptance/run.sh --check
```

CI builds the desktop bundle and runs both checks. For the opt-in live test,
follow the [desktop acceptance instructions](native/macos/Desktop/Acceptance/README.md)
and run `native/macos/Desktop/Acceptance/run.sh --run` in a graphical session
with the documented permissions. Headless checks do not verify live window focus.

For opt-in pan measurements, launch the manager with an absolute `INFINITEDESK_TEST_STATE_PATH` (the acceptance harness configures this). Its atomic JSON snapshot includes `pan.continuousWorker`, `continuousDelivery`, `discreteWorker` and `discreteDelivery`, each with total successful batch count, the latest 512 samples in milliseconds and p50/p95/p99. Continuous samples describe applied nonzero AX batches, including accepted-frame readback and journal durability; delivery additionally includes queue wait and main-thread result delivery. Discrete page navigation is recorded separately and excludes subsequent arrival-focus work. `coalescedPackets` counts input packets merged while the camera worker is occupied; `failedBatches` counts failed measured batches. These numbers measure application processing, not physical display output, input-to-photon latency or a verified frame rate. Samples are retained in memory; the existing background snapshot writer coalesces exports and computes percentiles only while encoding. Metrics are disabled in ordinary launches; `INFINITEDESK_PAN_METRICS=1` enables in-memory collection without a file export.

## Board prototype and benchmarks

The earlier board prototype is a separate development app. It needs Rust 1.99.1 (selected by `rust-toolchain.toml`) and a Metal-capable GPU. Graphical board checks ran on macOS 27.0.1. Full Xcode and Instruments are required for profiling.

```sh
./scripts/build-macos-app.sh --board
open "target/InfiniteDesk Board.app"
```

Two empty cards open side by side. Click **Use real window…** in a card,
choose a running app and select its window. With Accessibility access,
InfiniteDesk places the original window over the card and gives it focus.
Type, click, scroll and use shortcuts in the application normally. This
mode does not require screen sharing.

Click an exposed part of the board or use ⌘Tab to return. You can drag
the card or pan the board, then click **Work in window** or press ⌘Return
with that card selected to place the window at the new location. The app
keeps its own title bar, and its minimum size can extend past the card.
**Restore** returns the window to its previous size and position and
detaches it after confirmation. An application can constrain resizing or
reject a position outside the usable screen. Normal quit also attempts to
restore attached windows. Card assignments last for the current session.

In the macOS GUI check, two windows belonging to one Chrome process were
placed on separate cards at 516 × 375 points. After a camera reset,
⌘Return placed the selected window at 554 × 403 and the other retained its
frame. In Finder, a file rename and a scroll through a 100-file folder worked
in the original window. Finder retained a larger size than requested.
Returning to the board shows a labeled card for each attached window.

**Web** opens an embedded WebKit browser with its own address bar.
Drag a title bar to move a card and bring it to the front. Press Escape in
the browser to return the keyboard to the board. With the board focused,
press N to add a third card, Tab to cycle selection, or Enter to center it.
For the 1,000-window synthetic scene, use the `--demo` command below.

**Preview…** uses the macOS sharing picker. **Web** stops capture only in
that card. Each capture is limited to 15 frames per second and 1600 × 1200
pixels. On macOS 15.2 or later, **Focus window** or ⌘Return with a captured
card selected asks macOS to bring the original window forward. This requires
Accessibility access and can fail when the window cannot be identified
uniquely. **Open app** activates the source application without choosing
between its windows. By default, clicking the live image focuses its source window.

To edit an ordinary text field in a captured Google Chrome window, select
the card by its title bar, choose **More… → Pick Chrome field…**, and click inside the field
in the live preview. **More… → Replace focused Chrome field…** uses the field already focused in Chrome.
Check the field name in the board form, enter the replacement, and choose
**Replace**. Escape cancels. Both commands replace the entire value and
require Accessibility access. The board checks the window and field again
before sending. If another Chrome window covers the field in desktop
coordinates, point selection can be unavailable. The command excludes
the address bar and password fields.

Run `native/macos/Browser/Tests/Native/run.sh` for placement geometry.
With a graphical session and Accessibility access for the test host, add
`--integration` to exercise exact window selection, resizing and restoration.
The [native input fixture](native/macos/Browser/Tests/Focus/Fixture/README.md)
provides two windows for checking clicks, scrolling and keyboard input.

Run `native/macos/Browser/Tests/run.sh` in a graphical macOS session to check
two independent capture streams. `native/macos/Browser/Tests/Focus/run.sh`
checks identity matching and self-focus rejection without opening windows.
Pass `--integration` to check focus between two windows of a separate test
process. It skips with status 77 if the test host lacks Accessibility access.
See [the two-window Chrome test](native/macos/Browser/Tests/Chrome/README.md)
to distinguish switching the original window from editing its page from the
board. Run `native/macos/Browser/Tests/Text/run.sh` for the role and
cancellation checks and `native/macos/Browser/Tests/Geometry/run.sh` for
preview coordinate conversion.

Install the optional verification tools with:

```sh
cargo install cargo-nextest --version 0.9.150 --locked
cargo install cargo-deny --version 0.20.2 --locked
cargo install cargo-audit --version 0.22.2 --locked
```

```sh
cargo run --release -p desk-app -- --demo --windows 1000 --seed 42
cargo run -p desk-app -- --help
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo nextest run --workspace --locked
cargo test --workspace --doc --locked
cargo deny check
cargo audit
cargo build --workspace --release --locked
```

The demo accepts window counts 100, 1000, 5000 and 10000; the default is 1000. The seed defaults to 42. Zero is rejected. Pass `--focus ID` to select and center a window initially; valid IDs range from 0 through the window count minus one. Set `RUST_LOG=info` to log the selected GPU adapter.

Controls:

- Left-drag a window to select, raise and move it.
- Middle-drag or Space + left-drag to pan. Mouse pan continues with inertia after release.
- Scroll or use two-finger trackpad scrolling to pan. Trackpad momentum is handled by macOS.
- Pinch, or hold Control or Command while scrolling, to zoom around the cursor.
- `R` resets the camera; `F` fits all visible windows; Enter centers the selected window.
- Tab / Shift + Tab cycles selection; Escape cancels the current gesture.

Close the native window to exit. The canvas redraws on demand and reconfigures its surface after a resize.

`desk-app` owns the event loop and window lifecycle; `desk-render` owns GPU resources. `desk-core` provides validated f64 world geometry, logical and physical coordinate conversion, a camera, and deterministic virtual window scenes. World coordinates are limited to ±1e12, zoom to 1e-7–100 logical pixels per world unit, and display scale to 0.25–16; these are application limits rather than macOS limits. At 1e12, f64 quantization is about 0.000122 world units. Rectangle edges are half-open; edge contact does not count as overlap. A zero-sized viewport is rejected, so callers skip viewport operations when minimized. The board prototype displays the selected window through a native layer. The board supports the Chrome field replacement described above. The separate macOS probe also exercises pointer and caret input against a test fixture. Titles use bundled IBM Plex Mono, with its license and provenance in `crates/desk-render/assets/`. Glyphs not supported by the bundled font may be unavailable. Text layouts are cached only for visible titles, so a title returning on-screen may be reshaped; new scales can also rasterize glyphs on redraw. Total font-cache memory and frame latency have not yet been measured. GPU behavior and native window interaction require a real graphical macOS session; CI checks do not exercise them. A lost GPU device causes a graceful exit; device recovery is deferred to a later renderer milestone.

The text stack currently depends on `ttf-parser` 0.25.1, which is unmaintained ([RUSTSEC-2026-0192](https://rustsec.org/advisories/RUSTSEC-2026-0192)); the font database loads only the bundled trusted font. It also uses `lru` 0.16.4, affected by [RUSTSEC-2026-0253](https://rustsec.org/advisories/RUSTSEC-2026-0253); glyphon uses Copy keys and `pop_lru`, while the advisory requires `pop` with a panicking key destructor. Both advisory-specific cargo-deny exceptions must be reviewed when upstream dependencies change and removed when replacements are available. `cargo audit` continues to report both warnings.

InfiniteDesk maintainers own these exceptions and must review them before beta and whenever the dependency graph or font sources change; the configuration does not expire them automatically.

## Performance measurements

```sh
cargo run --release -p desk-app -- --benchmark --windows 1000 --seed 42 --scenario sparse --warmup 3 --duration 30 --target-hz 60 --output /tmp/infinitedesk-benchmark.json
cargo run --release -p desk-app -- --microbench --windows 10000 --scenario dense --output /tmp/infinitedesk-microbench.json
```

Benchmark scenarios are `sparse`, `dense` and `fit-all`. The reference frequency is a user-selected threshold, not a measurement of the display's refresh rate. Long intervals exceed 1.5 reference periods. Intervals measure returns from the rendering function, including CPU work after the present call; they are not physical presentation times. The benchmark requests an active always-on-top window to reduce occlusion; the OS may ignore these hints. It waits up to 10 seconds for an initial render completion; after that it exits incomplete if the window is occluded or its viewport changes. Pass `--gpu-timestamps` to request asynchronous timestamps around the canvas render pass when the adapter supports them. The elapsed timestamp interval may include preemption or overlap and is not exclusive GPU busy time; it does not measure presentation or input latency. The renderer submits timestamp resolve and readback only after the sampled frame submission completes; this adds GPU submissions and CPU polling overhead. The report records query coverage, skipped slots, readback failures and the bounded drain result; GPU statistics are unavailable if any timestamp pair is invalid or measurement coverage is incomplete. An earlier inline-resolve diagnostic on macOS 27.0.1/Apple M4 produced repeated zero and non-monotonic timestamps; incomplete or invalid runs must not be used as GPU performance baselines. Without the option or on unsupported adapters GPU timing is unavailable. Physical present latency, input latency, CPU usage, RSS and allocation counts are not currently measured in the report.

On macOS, `/usr/bin/time -l -- target/release/desk-app --benchmark ...` reports peak RSS and user/system CPU for the complete process, including startup, report export and child processes used for source identity. Capture its stderr separately from the JSON report; those figures are not per-frame measurements or GPU memory usage.

## macOS window feasibility probe

`native/macos/Stage6Probe/build.sh` builds two ad-hoc signed experimental apps in `target/native-probe`. Open **InfiniteDesk Probe.app** to inspect permission status without requesting access. Its buttons explicitly request Screen Recording or Accessibility; grant access only when ready to test. Launch the synthetic fixture from the probe, then start capture and optionally enable fixture-only input. Right-drag pans; zoom controls select 0.5×, 1×, or 2×. No real user document is needed.

Select **Mouse AppKit local CG** by cycling the mouse-mode button three times. On macOS 27.0.1, clicking the captured **Sheet** button opened the fixture's dialog at 0.5×, 1× and 2×. Clicking the captured text editor in the inactive fixture delivered matching coordinates but left the text unchanged on the next keystroke. With the fixture active, its window key and its text view focused, the probe moved the caret, inserted a character and replaced a dragged selection. The receiving window reports its ID, local coordinates, mouse event numbers, hit view and activation state so the two cases can be reproduced.

To type into the background fixture, choose **AX text ON** and **Input ON**.
Bring the Probe window to the front, click the first line of text in its
preview and type. This mode uses the clicked text control's Accessibility
range to place the caret. On macOS 27.0.1 the Probe kept keyboard focus while
the fixture received text at 0.5×, 1× and 2×. Click the empty board to stop
sending keystrokes to that editor. The mouse-mode selector applies when
**AX text** is off.

Both experiments use the fixture's own window identifier. The pointer modes
use an empirical coordinate conversion. Third-party window identity, IME and
routing across dialogs remain open. The AppKit probe runs separately from the
Rust/Metal canvas. Its local mouse monitor sees normal fixture dispatch and
may miss events in nested tracking loops.

**Launch browser** starts installed Google Chrome with a temporary profile and
a local test page. Start capture, bring Probe to the front, turn Input on and
click **Press me** in the preview. **Browser AX** uses the Accessibility press
action. Switch to **Browser Pointer** and enable input again to send a mouse
down/up pair to the isolated Chrome process. **Show browser** activates the
source application and disables forwarding. On macOS 27.0.1, capture worked
and the page counter stayed at zero with both background delivery modes.
Two direct pointer clicks in headless Chrome advanced the same page from
zero to two. Reproduce that control with the commands in
[`BrowserPointerControl.cjs`](native/macos/Stage6Probe/BrowserPointerControl.cjs).

The probe keeps one latest-frame slot in memory and limits each accepted buffer to 32 MiB. It disables input after two seconds without a complete or idle capture callback. Recheck permission status after rebuilding either ad-hoc signed app.
