# Real AX worker benchmark

Opt-in macOS benchmark for production `DesktopWindowBackend.panCamera` and its real
Accessibility IPC. The accessor launches a disposable child AppKit process with
2/4/8 ordinary original windows (configurable, e.g. 2/5/10). Registration uses
fixture-only pipe commands to make each native window key. Originals use a
deterministic grid. Registration waits for three consecutive stable focused AX
frames, each matching exactly one on-screen CoreGraphics window, then checks
current-Space geometry again after capture. A zero-delta candidate validation
rejects setup/scope failures before warm-up or measured samples. Every AX read/write
is guarded by the child's PID. No keyboard/mouse events are synthesized, no
existing application windows are registered, and no permission settings change.

Build and headless verification:

```sh
native/macos/Desktop/Benchmarks/AX/build.sh
```

This compiles optimized Swift 6/macOS 15 production sources, signs the dedicated
`org.infinitedesk.tests.ax-benchmark` app, verifies its signature and runs only
statistics/CLI validation. It never initializes AppKit, checks permissions or
opens windows during the headless self-test. Use `INFINITEDESK_SIGN_IDENTITY` to
select your own normal signing identity; default signing is ad hoc.

## Scalar default and opt-in bulk experiment

The default build uses scalar reads, matching the shipping `SystemDesktopAXAccess`
strategy. `GuardedAX.readMultiple` delegates to its counted/guarded `read` for each
attribute. To experiment with native `AXUIElementCopyMultipleAttributeValues`, set
`INFINITEDESK_AX_BATCH_EXPERIMENT=1`; this is the only route that passes Swift's
`-D DESKTOP_AX_BATCH_EXPERIMENT`. Values other than `0` and `1` are rejected.
Keep separate cache tags for the two modes:

```sh
INFINITEDESK_BENCH_STAGE=0 \
  native/macos/Desktop/Benchmarks/AX/build.sh "$PWD" current-scalar
INFINITEDESK_AX_BATCH_EXPERIMENT=1 INFINITEDESK_BENCH_STAGE=0 \
  native/macos/Desktop/Benchmarks/AX/build.sh "$PWD" current-bulk
INFINITEDESK_BENCH_STAGE=0 \
  native/macos/Desktop/Benchmarks/AX/build.sh "$baseline" baseline-scalar
```

All commands above compile/test caches without staging or opening an app. To
stage a chosen variant later, repeat that exact command with
`INFINITEDESK_BENCH_STAGE=0` removed, retaining the experiment flag only for bulk.
Use your normal signing identity when staging. Reusing a tag across modes is safe
but recompiles because the mode participates in the build fingerprint.

Each cache and staged app contains `build-configuration.json` with
`batchExperiment`, `readStrategy` (`scalar` or `bulk-experiment`) and `swiftDefines`.
The report copies this object as `buildConfiguration`, and the executable verifies
that the manifest agrees with its compiled mode. The five production source
hashes and harness hash remain separate in `sourceFingerprints`. The pre-batching
`c9ff017` protocol never calls the extra wrapper method; use scalar mode for that
baseline and inspect actual call counters when comparing experiments.

Earlier raw JSON files predate the explicit mode field and remain unchanged.
In `target/desktop-ax-benchmark/`, `profile-current.json`,
`profile-batched-reverse.json`, and `profile-restoration.json` are **bulk experiment**
runs; their nonzero `multipleReads` counters establish the strategy. The first two
compare the earlier production source, while `profile-restoration.json` additionally
includes the parked-window restoration correction. `profile-current-edge.json`
is failed bulk evidence. `profile-baseline.json` and
`profile-baseline-reverse.json` are scalar `c9ff017` runs. Those previous bulk
measurements are not timings for the selected shipping scalar configuration;
new scalar reports require a separate explicitly authorized live run.

## Live run (explicit GUI session)

Grant **InfiniteDesk AX Benchmark** Accessibility access using normal macOS
System Settings. This is a separate app at a stable path; the product app's grant
does not grant this executable access. The benchmark never prompts or changes
TCC; it writes `status: skipped` and exits 77 if untrusted. Rebuilding an ad-hoc
signed binary can invalidate its grant; use the same development signing identity
for both A/B builds and review the grant normally if macOS requires it.

Close unrelated test managers, use exactly one display and do not interact with
the Mac while it runs. Each count creates temporary fixture windows and briefly
activates the disposable child. An additional small control window is never registered
and stays visible while all measured originals are parked. A foreground change during sampling aborts the
run and sets `foregroundInterference`; the benchmark does not reclaim focus.

```sh
open -W -n -g -j \
  "$PWD/target/desktop-ax-benchmark/InfiniteDesk AX Benchmark.app" \
  --args --run --output /tmp/ax-current.json \
  --counts 2,4,8 --samples 120 --edge-samples 20 --label current
```

`open`'s status is a launcher result; inspect the JSON `status`, every run's
`cleanupRestored`, and `foregroundInterference`. Interrupted/failed runs are not
performance results. Each successful run restores its own original positions
through the production pause path, then terminates the disposable child. On
restoration failure, the run fails, preserves its isolated temporary recovery
journal path in `error`, and still terminates only its disposable child. Never
reuse this journal for a product session.

## Same harness against baseline and current

The harness stays in the current checkout. Its optional source-root argument
selects only the five production Swift files; it does not switch, modify or
commit either checkout. Both builds replace the same dedicated benchmark app.
Pass a cache tag as the second build argument, e.g. `build.sh "$baseline" baseline`
and `build.sh "$PWD" current`. Matching source/toolchain fingerprints reuse the
compiled executable under `target/desktop-ax-benchmark/cache/TAG/`; each call
still copies it into the stable dedicated app, signs and verifies normally.
Set `INFINITEDESK_BENCH_STAGE=0` to compile/check a variant into its cache
without changing the stable app (including while another variant is running).
After it exits, run the same build command without that variable to stage/sign
the cached variant in well under a second on an unchanged checkout. Do not
replace/sign the stable app while its benchmark process is running.
Do not launch raw cache executables for a live run.

The JSON includes SHA256 fingerprints of all five production source files and
the harness; user-supplied `--label` is a label, not source verification.
Use matching counts/samples/edge-samples, same display/OS and signing identity, and run A/B
back-to-back (preferably also reverse order). Save each report before rebuilding.

```sh
baseline=$(mktemp -d /tmp/infinitedesk-ax-baseline.XXXXXXXX)
git archive c9ff017 native/macos/Desktop | tar -x -C "$baseline"
native/macos/Desktop/Benchmarks/AX/build.sh "$baseline"
open -W -n -g -j \
  "$PWD/target/desktop-ax-benchmark/InfiniteDesk AX Benchmark.app" \
  --args --run --output /tmp/ax-c9ff017.json \
  --counts 2,4,8 --samples 120 --edge-samples 20 --label c9ff017
native/macos/Desktop/Benchmarks/AX/build.sh
open -W -n -g -j \
  "$PWD/target/desktop-ax-benchmark/InfiniteDesk AX Benchmark.app" \
  --args --run --output /tmp/ax-current.json \
  --counts 2,4,8 --samples 120 --edge-samples 20 --label current
```

## Measurement boundaries

- Timings start inside the production serial AX queue and include the complete
  synchronous `panCamera` batch: real native IPC, readback, durable recovery
  journal work, publication and PID guards. The wrapper's `readMultiple` issues
  scalar reads by default and native `AXUIElementCopyMultipleAttributeValues`
  only in the explicitly enabled bulk experiment; on `c9ff017` the older protocol
  never calls this additional method. Counts expose individual reads, batched
  reads, requested attributes, guards, settable checks, position writes and
  minimize/restore writes. Do not interpret these as kernel IPC counters.
  Extra PID guards add cost per wrapper call, so timings include benchmark
  overhead and do not isolate the product speedup alone.
- Twelve normal warm-up batches precede measured alternating +2/-2 pt movement.
  All originals must move in every normal sample. Four edge warm-up batches
  precede measured +/-two display widths; every original must park or unpark.
  Normal, park and unpark have separate nearest-rank p50/p95/p99, sample counts,
  raw times and counters. Empty distributions encode null, never a fake zero.
  `--samples` controls normal batches (even, 20...1000); `--edge-samples` controls
  edge batches independently (even, 0...1000). Zero disables both edge warm-up
  and edge measurement, yielding a normal-only run with empty/null park/unpark
  distributions. Use `--edge-samples 0` for matched normal-only A/B. Default 20 edge batches give only
  10 samples per direction: their p99 is a small-sample statistic. For a quick
  smoke run, use `--counts 2,5,10 --samples 40 --edge-samples 2`; allow roughly
  1–3 minutes including warm-up and native Dock animations. This runtime is an
  estimate, not an observed result; one sample per edge direction cannot estimate
  tail latency meaningfully.
- AppKit fixture and accessor run in separate PIDs, so native AX uses the real
  cross-process path. Observation delivery is disabled intentionally to isolate
  synchronous worker batches. The real production identity, permission and
  current-Space checks remain. Input coalescing, queue wait, rendering,
  compositor smoothness, production observer load and end-to-end pan delivery
  are not measured. This supplements product profiling; it does not replace it.
- RSS uses `proc_pidinfo(PROC_PIDTASKINFO).pti_resident_size` before and after each
  count, separately for accessor and fixture. Missing readings are absent, not
  zero. These snapshots are not an allocation profile, a peak, a leak test, or
  WindowServer/GPU memory. Accessor RSS may retain caches between counts.
- The app requires a graphical macOS login, one display, and an explicit normal
  Accessibility grant. Build/self-test success is not a live benchmark pass.

## Edge failure under investigation

The initial live `c9ff017` run reported a park failure in `confirm-minimized`:
`AXSubrole is unavailable or is not AXStandardWindow`, followed by restoration
preflight failure with the same message. This report is failed evidence and must
not be presented as passing edge timings. That message alone does not distinguish
a native AX error, an absent attribute, or a concrete alternate subrole.

`axDiagnostics` now captures unexpected raw subroles, their CF type and native AX
status, plus the last requested park/unpark action. For each changed abnormal
signature it additionally snapshots role, minimized/fullscreen, exact retained
handle membership in the child AXWindows, PID and process birth. These four extra
attribute reads occur only after an already-invalid identity result, and are
counted; successful normal timings do not include those diagnostic reads. It reads only benchmark child
elements. No registration or production validation gate is relaxed. A normal-only
run does not reproduce or fix the edge issue; keep the original failed report and
isolated recovery evidence for the separate correctness investigation.

Every failed worker batch records `failedBatch` before cleanup: phase, delta,
elapsed time, exact call counters, camera state, and each registered window's
availability, observationDetail, minimized ownership and frames. The same
structured object is included in the error text for quick inspection. Setup
and post-batch guard failures record the most recent worker state separately.
These diagnostics distinguish skipped candidates from a missing position write;
cleanup cannot overwrite the failed batch's counters or reason.
