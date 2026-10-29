# InfiniteDesk

Native macOS application for an infinite desktop. The current milestone renders a deterministic 1,000-window scene in one Metal-backed canvas; navigation and real-window integration are not implemented yet.

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
cargo run -p desk-app
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo nextest run --workspace --locked
cargo test --workspace --doc --locked
cargo deny check
cargo audit
cargo build --workspace --release --locked
```

Set `RUST_LOG=info` to log the selected GPU adapter. Close the window to exit. The app redraws on demand and reconfigures its surface after a resize.

`desk-app` owns the event loop and window lifecycle; `desk-render` owns GPU resources. `desk-core` provides validated f64 world geometry, logical and physical coordinate conversion, a camera, and deterministic virtual window scenes. World coordinates are limited to ±1e12, zoom to 0.01–100 logical pixels per world unit, and display scale to 0.25–16; these are application limits rather than macOS limits. At 1e12, f64 quantization is about 0.000122 world units. Rectangle edges are half-open; edge contact does not count as overlap. A zero-sized viewport is rejected, so callers skip viewport operations when minimized. The current canvas is static; input, benchmark, capture, and accessibility adapters are not yet implemented. Titles use bundled IBM Plex Mono, with its license and provenance in `crates/desk-render/assets/`. Glyphs not supported by the bundled font may be unavailable. Text layouts are cached only for visible titles, so a title returning on-screen may be reshaped; new scales can also rasterize glyphs on redraw. Total font-cache memory and frame latency have not yet been measured. GPU behavior and native window interaction require a real graphical macOS session; CI checks do not exercise them. A lost GPU device causes a graceful exit; device recovery is deferred to a later renderer milestone.

The text stack currently depends on `ttf-parser` 0.25.1, which is unmaintained ([RUSTSEC-2026-0192](https://rustsec.org/advisories/RUSTSEC-2026-0192)); the font database loads only the bundled trusted font. It also uses `lru` 0.16.4, affected by [RUSTSEC-2026-0253](https://rustsec.org/advisories/RUSTSEC-2026-0253); glyphon uses Copy keys and `pop_lru`, while the advisory requires `pop` with a panicking key destructor. Both advisory-specific cargo-deny exceptions must be reviewed when upstream dependencies change and removed when replacements are available. `cargo audit` continues to report both warnings.

InfiniteDesk maintainers own these exceptions and must review them before beta and whenever the dependency graph or font sources change; the configuration does not expire them automatically.
