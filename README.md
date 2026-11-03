# InfiniteDesk

Native macOS application for an infinite desktop. The demo renders and navigates a deterministic virtual-window scene in one Metal-backed canvas. Real-window integration is not implemented yet.

## Requirements

- macOS 15.0 or later on Apple Silicon with a Metal-capable GPU
- Rust 1.99.1, installed automatically by rustup from `rust-toolchain.toml`
- Apple Command Line Tools or Xcode

The deployment target is macOS 15.0; graphical behavior has been tested on macOS 27.0.1, not yet on 15.0. Full Xcode and Instruments are required for profiling; the Command Line Tools alone do not provide them.

## Run and verify

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

Selection applies to demo windows only. Close the native window to exit. The app redraws on demand and reconfigures its surface after a resize.

`desk-app` owns the event loop and window lifecycle; `desk-render` owns GPU resources. `desk-core` provides validated f64 world geometry, logical and physical coordinate conversion, a camera, and deterministic virtual window scenes. World coordinates are limited to ±1e12, zoom to 1e-7–100 logical pixels per world unit, and display scale to 0.25–16; these are application limits rather than macOS limits. At 1e12, f64 quantization is about 0.000122 world units. Rectangle edges are half-open; edge contact does not count as overlap. A zero-sized viewport is rejected, so callers skip viewport operations when minimized. Native capture and accessibility adapters are not yet implemented. Titles use bundled IBM Plex Mono, with its license and provenance in `crates/desk-render/assets/`. Glyphs not supported by the bundled font may be unavailable. Text layouts are cached only for visible titles, so a title returning on-screen may be reshaped; new scales can also rasterize glyphs on redraw. Total font-cache memory and frame latency have not yet been measured. GPU behavior and native window interaction require a real graphical macOS session; CI checks do not exercise them. A lost GPU device causes a graceful exit; device recovery is deferred to a later renderer milestone.

The text stack currently depends on `ttf-parser` 0.25.1, which is unmaintained ([RUSTSEC-2026-0192](https://rustsec.org/advisories/RUSTSEC-2026-0192)); the font database loads only the bundled trusted font. It also uses `lru` 0.16.4, affected by [RUSTSEC-2026-0253](https://rustsec.org/advisories/RUSTSEC-2026-0253); glyphon uses Copy keys and `pop_lru`, while the advisory requires `pop` with a panicking key destructor. Both advisory-specific cargo-deny exceptions must be reviewed when upstream dependencies change and removed when replacements are available. `cargo audit` continues to report both warnings.

InfiniteDesk maintainers own these exceptions and must review them before beta and whenever the dependency graph or font sources change; the configuration does not expire them automatically.

## Performance measurements

```sh
cargo run --release -p desk-app -- --benchmark --windows 1000 --seed 42 --scenario sparse --warmup 3 --duration 30 --target-hz 60 --output /tmp/infinitedesk-benchmark.json
cargo run --release -p desk-app -- --microbench --windows 10000 --scenario dense --output /tmp/infinitedesk-microbench.json
```

Benchmark scenarios are `sparse`, `dense` and `fit-all`. The reference frequency is a user-selected threshold, not a measurement of the display's refresh rate. Long intervals exceed 1.5 reference periods. Intervals measure returns from the rendering function, including CPU work after the present call; they are not physical presentation times. The benchmark requests an active always-on-top window to reduce occlusion; the OS may ignore these hints. It waits up to 10 seconds for an initial render completion; after that it exits incomplete if the window is occluded or its viewport changes. Pass `--gpu-timestamps` to request asynchronous timestamps around the canvas render pass when the adapter supports them. The elapsed timestamp interval may include preemption or overlap and is not exclusive GPU busy time; it does not measure presentation or input latency. The renderer submits timestamp resolve and readback only after the sampled frame submission completes; this adds GPU submissions and CPU polling overhead. The report records query coverage, skipped slots, readback failures and the bounded drain result; GPU statistics are unavailable if any timestamp pair is invalid or measurement coverage is incomplete. An earlier inline-resolve diagnostic on macOS 27.0.1/Apple M4 produced repeated zero and non-monotonic timestamps; incomplete or invalid runs must not be used as GPU performance baselines. Without the option or on unsupported adapters GPU timing is unavailable. Physical present latency, input latency, CPU usage, RSS and allocation counts are not currently measured in the report.

On macOS, `/usr/bin/time -l -- target/release/desk-app --benchmark ...` reports peak RSS and user/system CPU for the complete process, including startup, report export and child processes used for source identity. Capture its stderr separately from the JSON report; those figures are not per-frame measurements or GPU memory usage.
