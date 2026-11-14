# InfiniteDesk

> [!WARNING]
> **Do not download or install InfiniteDesk.** The project is unfinished. The build instructions below are for development and testing only.

InfiniteDesk is a macOS menu bar app for registering and focusing real application windows. Registration reads the focused window where it is. You can then switch between registered windows, including two windows belonging to the same app. This first desktop mode keeps registrations for the current session. Panning between distant windows and the zoomed-out overview are planned.

## Build and try the desktop manager

Build on an Apple Silicon Mac with Xcode or Apple Command Line Tools that support Swift 6. The minimum deployment target is macOS 15.

```sh
./scripts/build-macos-app.sh
open target/InfiniteDesk.app
```

Open the InfiniteDesk icon in the menu bar and grant Accessibility access when requested. For local development, set `INFINITEDESK_SIGN_IDENTITY` to your Apple Development signing identity before building if you want a consistent signing identity across builds. The default is an ad-hoc signature, so macOS may request permission again after rebuilding.

1. Focus a window and press **⌃⌥⌘W** to register it. Repeat with a second window.
2. Press **⌃⌥⌘←** or **⌃⌥⌘→** to focus the previous or next registered window. Type directly in the original application.
3. To choose a specific registration, use the InfiniteDesk menu. The menu also shows the latest operation and any shortcut conflicts.

Run the desktop checks without opening windows or granting Accessibility access:

```sh
native/macos/Desktop/Tests/run.sh
native/macos/Desktop/Acceptance/run.sh --check
```

CI builds the desktop bundle and runs both checks. For the opt-in live test,
follow the [desktop acceptance instructions](native/macos/Desktop/Acceptance/README.md)
and run `native/macos/Desktop/Acceptance/run.sh --run` in a graphical session
with the documented permissions. Headless checks do not verify live window focus.

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
