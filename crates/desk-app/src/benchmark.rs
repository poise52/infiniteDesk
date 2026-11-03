use crate::{
    cli::{Options, Scenario},
    interaction::Board,
};
use anyhow::{Context, Result};
use desk_core::{Camera, WindowId, WorldPoint};
use desk_render::{FrameMetrics, GpuReport};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    path::Path,
    process::Command,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const MAX_SAMPLES: usize = 200_000;
#[derive(Debug, Serialize)]
struct Identity {
    commit: Option<String>,
    source_sha256: String,
    binary_sha256: String,
    source_dirty: bool,
    source_hash_scope: &'static str,
}
fn hash_file(hasher: &mut Sha256, path: &Path) -> Result<()> {
    let data = std::fs::read(path).with_context(|| format!("reading {}", path.display()))?;
    hasher.update((data.len() as u64).to_le_bytes());
    hasher.update(data);
    Ok(())
}
fn source_path(path: &str) -> bool {
    Path::new(path).extension().is_some_and(|ext| {
        ["rs", "wgsl", "ttf"]
            .iter()
            .any(|candidate| ext.eq_ignore_ascii_case(candidate))
    }) || path.ends_with("Cargo.toml")
        || path == "Cargo.lock"
        || path == "rust-toolchain.toml"
        || path == ".cargo/config.toml"
}
fn identity() -> Result<Identity> {
    let output = Command::new("git")
        .args([
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "-z",
        ])
        .output()
        .context("listing source files")?;
    anyhow::ensure!(output.status.success(), "git ls-files failed");
    let mut files: Vec<_> = output
        .stdout
        .split(|b| *b == 0)
        .filter(|b| !b.is_empty())
        .map(std::str::from_utf8)
        .collect::<std::result::Result<_, _>>()?;
    files.retain(|path| source_path(path));
    files.sort_unstable();
    files.dedup();
    let mut source = Sha256::new();
    for path in &files {
        source.update((path.len() as u64).to_le_bytes());
        source.update(path.as_bytes());
        hash_file(&mut source, Path::new(path))?;
    }
    let status = Command::new("git")
        .args(["status", "--porcelain=v1", "--untracked-files=all", "-z"])
        .output()
        .context("checking source status")?;
    anyhow::ensure!(status.status.success(), "git status failed");
    let dirty = status
        .stdout
        .split(|b| *b == 0)
        .filter_map(|record| std::str::from_utf8(record).ok())
        .any(|entry| entry.len() >= 4 && source_path(&entry[3..]));
    let head = Command::new("git")
        .args(["rev-parse", "HEAD"])
        .output()
        .context("reading git commit")?;
    let commit = head
        .status
        .success()
        .then(|| String::from_utf8_lossy(&head.stdout).trim().to_owned());
    let binary_bytes = std::fs::read(std::env::current_exe()?).context("reading executable")?;
    let binary = Sha256::digest(binary_bytes);
    Ok(Identity {
        commit,
        source_sha256: format!("{:x}", source.finalize()),
        binary_sha256: format!("{binary:x}"),
        source_dirty: dirty,
        source_hash_scope: "runtime working tree: Rust, WGSL, fonts, Cargo manifests/lock, toolchain and cargo config; executable hash is definitive",
    })
}

#[derive(Debug, Serialize)]
struct SystemInfo {
    macos_version: String,
    macos_build: String,
    model: String,
    cpu: String,
    logical_cpus: String,
    memory_bytes: String,
    debug_assertions: bool,
}
fn system_value(program: &str, args: &[&str]) -> String {
    Command::new(program)
        .args(args)
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map_or_else(
            || "unavailable".to_owned(),
            |output| String::from_utf8_lossy(&output.stdout).trim().to_owned(),
        )
}
fn system_info() -> SystemInfo {
    SystemInfo {
        macos_version: system_value("sw_vers", &["-productVersion"]),
        macos_build: system_value("sw_vers", &["-buildVersion"]),
        model: system_value("sysctl", &["-n", "hw.model"]),
        cpu: system_value("sysctl", &["-n", "machdep.cpu.brand_string"]),
        logical_cpus: system_value("sysctl", &["-n", "hw.logicalcpu"]),
        memory_bytes: system_value("sysctl", &["-n", "hw.memsize"]),
        debug_assertions: cfg!(debug_assertions),
    }
}

#[derive(Debug, Serialize)]
struct Sample {
    elapsed_seconds: f64,
    interval_ms: f64,
    update_ms: f64,
    frame: FrameMetrics,
}
#[derive(Debug, Serialize)]
struct Statistics {
    count: usize,
    average_fps: f64,
    median_fps: f64,
    one_percent_low_fps: f64,
    interval_ms_p50: f64,
    interval_ms_p95: f64,
    interval_ms_p99: f64,
    long_intervals: usize,
}
#[allow(clippy::cast_precision_loss)]
fn stats(intervals: &[f64], target_hz: u32) -> Option<Statistics> {
    if intervals.is_empty() || intervals.iter().any(|v| !v.is_finite() || *v <= 0.0) {
        return None;
    }
    let mut sorted = intervals.to_vec();
    sorted.sort_unstable_by(f64::total_cmp);
    let n = sorted.len();
    let rank = |numerator: usize| sorted[(n * numerator).div_ceil(100).saturating_sub(1)];
    let sum: f64 = sorted.iter().sum();
    let slow_count = n.div_ceil(100);
    let slow_mean = sorted[n - slow_count..].iter().sum::<f64>() / slow_count as f64;
    Some(Statistics {
        count: n,
        average_fps: 1000.0 * n as f64 / sum,
        median_fps: 1000.0 / rank(50),
        one_percent_low_fps: 1000.0 / slow_mean,
        interval_ms_p50: rank(50),
        interval_ms_p95: rank(95),
        interval_ms_p99: rank(99),
        long_intervals: sorted
            .iter()
            .filter(|v| **v > 1500.0 / f64::from(target_hz))
            .count(),
    })
}

fn gpu_measurement_values(samples: &[Sample], gpu: &[desk_render::GpuSample]) -> Vec<f64> {
    let sample_ids: std::collections::HashSet<_> =
        samples.iter().map(|sample| sample.frame.frame_id).collect();
    let mut values: Vec<_> = gpu
        .iter()
        .filter(|sample| sample_ids.contains(&sample.frame_id))
        .map(|sample| sample.render_pass_ms)
        .collect();
    values.sort_unstable_by(f64::total_cmp);
    values
}

const fn gpu_statistics_unavailable_reason(
    gpu: &GpuReport,
    expected: usize,
    matched: usize,
    completed: bool,
) -> Option<&'static str> {
    if !completed {
        Some("benchmark incomplete")
    } else if !gpu.enabled {
        Some("timestamp measurement unavailable or disabled")
    } else if gpu.invalid_timestamps_total > 0 {
        Some("invalid timestamp pairs observed; all pairs are untrusted")
    } else if gpu.map_errors_total > 0 || gpu.poll_errors_total > 0 {
        Some("timestamp readback or polling failed")
    } else if gpu.pending_at_drain_end > 0 {
        Some("timestamp readbacks remained pending after bounded drain")
    } else if expected == 0 {
        Some("no measured CPU frames")
    } else if matched != expected {
        Some("incomplete measurement frame coverage")
    } else {
        None
    }
}

fn stage_percentiles(samples: &[Sample]) -> serde_json::Value {
    if samples.is_empty() {
        return serde_json::json!("unavailable");
    }
    let mut stages = serde_json::Map::new();
    for (name, values) in [
        (
            "update",
            samples.iter().map(|s| s.update_ms).collect::<Vec<_>>(),
        ),
        (
            "acquire",
            samples.iter().map(|s| s.frame.acquire_ms).collect(),
        ),
        (
            "geometry",
            samples.iter().map(|s| s.frame.geometry_ms).collect(),
        ),
        (
            "upload",
            samples.iter().map(|s| s.frame.upload_ms).collect(),
        ),
        ("text", samples.iter().map(|s| s.frame.text_ms).collect()),
        (
            "encode",
            samples.iter().map(|s| s.frame.encode_ms).collect(),
        ),
        (
            "submit",
            samples.iter().map(|s| s.frame.submit_ms).collect(),
        ),
        (
            "present_call",
            samples.iter().map(|s| s.frame.present_call_ms).collect(),
        ),
    ] {
        let mut sorted = values;
        sorted.sort_unstable_by(f64::total_cmp);
        let n = sorted.len();
        let rank = |p: usize| sorted[(n * p).div_ceil(100) - 1];
        stages.insert(
            name.to_owned(),
            serde_json::json!({"p50":rank(50),"p95":rank(95),"p99":rank(99)}),
        );
    }
    let mut poll: Vec<_> = samples
        .iter()
        .filter_map(|sample| sample.frame.gpu_poll_ms)
        .collect();
    if !poll.is_empty() {
        poll.sort_unstable_by(f64::total_cmp);
        let n = poll.len();
        let rank = |p: usize| poll[(n * p).div_ceil(100) - 1];
        stages.insert(
            "gpu_poll".to_owned(),
            serde_json::json!({"p50":rank(50),"p95":rank(95),"p99":rank(99)}),
        );
    }
    serde_json::Value::Object(stages)
}

#[derive(Debug)]
pub struct Benchmark {
    options: Options,
    identity: Identity,
    system: SystemInfo,
    pub start: Instant,
    pub deadline: Instant,
    pub started: bool,
    startup_elapsed_ms: Option<f64>,
    startup_occluded: u64,
    previous: Option<Instant>,
    samples: Vec<Sample>,
    pub completed: bool,
    pub incomplete: Option<String>,
    retries: u64,
    last_metrics: Option<FrameMetrics>,
    adapter: String,
    present_mode: String,
    validation_flags: String,
    limits: String,
    timestamp_supported: bool,
    width: u32,
    height: u32,
    scale: f64,
    base_camera: Camera,
    origins: Vec<(WindowId, WorldPoint)>,
}
impl Benchmark {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        options: Options,
        board: &mut Board,
        width: u32,
        height: u32,
        scale: f64,
        adapter: String,
        present_mode: String,
        validation_flags: String,
        limits: String,
        timestamp_supported: bool,
    ) -> Result<Self> {
        let identity = identity()?;
        if options.scenario == Scenario::Dense {
            densify(board, options.windows)?;
        }
        if options.scenario == Scenario::FitAll {
            anyhow::ensure!(board.fit_all(), "cannot fit scene in benchmark viewport");
        }
        let base_camera = board.camera;
        let origins = board
            .scene
            .windows()
            .iter()
            .take(3)
            .map(|w| (w.id(), w.bounds().origin()))
            .collect();
        let start = Instant::now();
        let deadline = start + Duration::from_secs(10);
        Ok(Self {
            options,
            identity,
            system: system_info(),
            start,
            deadline,
            started: false,
            startup_elapsed_ms: None,
            startup_occluded: 0,
            previous: None,
            samples: Vec::with_capacity(4096),
            completed: false,
            incomplete: None,
            retries: 0,
            last_metrics: None,
            adapter,
            present_mode,
            validation_flags,
            limits,
            timestamp_supported,
            width,
            height,
            scale,
            base_camera,
            origins,
        })
    }
    pub fn begin_after_init(&mut self) {
        self.start = Instant::now();
        self.deadline = self.start + Duration::from_secs(10);
    }
    pub fn first_frame_completed(&mut self, now: Instant) {
        if !self.started {
            self.startup_elapsed_ms =
                Some(now.saturating_duration_since(self.start).as_secs_f64() * 1000.0);
            self.start = now;
            self.deadline =
                now + Duration::from_secs(self.options.warmup + self.options.duration + 5);
            self.previous = None;
            self.started = true;
        }
    }
    pub const fn startup_occluded(&mut self) {
        self.startup_occluded += 1;
    }
    pub fn update(&self, board: &mut Board, now: Instant) -> Result<f64> {
        let mark = Instant::now();
        let seconds = now.saturating_duration_since(self.start).as_secs_f64();
        let (dx, dy, zoom, drag) = trajectory(seconds, self.base_camera.zoom());
        let center = self.base_camera.center();
        let camera = Camera::new(WorldPoint::new(center.x() + dx, center.y() + dy)?, zoom)?;
        let viewport = desk_core::Viewport::new(self.width, self.height, self.scale)?;
        camera.bounds(viewport)?;
        board.camera = camera;
        for (id, initial) in &self.origins {
            let origin = board
                .scene
                .get(*id)
                .context("benchmark window disappeared")?
                .bounds()
                .origin();
            board.scene.drag(
                *id,
                initial.x() + drag - origin.x(),
                initial.y() - origin.y(),
            )?;
        }
        Ok(mark.elapsed().as_secs_f64() * 1000.0)
    }
    #[allow(clippy::cast_precision_loss)]
    pub fn record(&mut self, now: Instant, update_ms: f64, metrics: FrameMetrics) {
        self.last_metrics = Some(metrics);
        let elapsed = now.saturating_duration_since(self.start).as_secs_f64();
        if elapsed < self.options.warmup as f64 {
            self.previous = None;
            return;
        }
        if let Some(previous) = self.previous {
            if self.samples.len() == MAX_SAMPLES {
                self.incomplete = Some("sample limit exceeded".into());
                return;
            }
            let interval_ms = now.saturating_duration_since(previous).as_secs_f64() * 1000.0;
            if interval_ms > 0.0 {
                self.samples.push(Sample {
                    elapsed_seconds: elapsed,
                    interval_ms,
                    update_ms,
                    frame: metrics,
                });
            }
        }
        self.previous = Some(now);
        if elapsed >= (self.options.warmup + self.options.duration) as f64 {
            self.completed = !self.samples.is_empty();
            if !self.completed {
                self.incomplete = Some("no cadence intervals measured".into());
            }
        }
    }
    pub const fn viewport_matches(&self, width: u32, height: u32, scale: f64) -> bool {
        self.width == width && self.height == height && self.scale.to_bits() == scale.to_bits()
    }
    pub const fn retry(&mut self) {
        self.retries += 1;
    }
    #[allow(clippy::cast_precision_loss)]
    pub fn finish(&self, gpu: &GpuReport) -> Result<()> {
        let intervals: Vec<_> = self.samples.iter().map(|s| s.interval_ms).collect();
        let stages = stage_percentiles(&self.samples);
        let gpu_values = gpu_measurement_values(&self.samples, &gpu.raw_gpu_samples);
        let gpu_reason = gpu_statistics_unavailable_reason(
            gpu,
            self.samples.len(),
            gpu_values.len(),
            self.completed,
        );
        let gpu_stats = if gpu_reason.is_some() {
            serde_json::json!("unavailable")
        } else {
            let n = gpu_values.len();
            let rank = |percent: usize| gpu_values[(n * percent).div_ceil(100) - 1];
            serde_json::json!({"count": n, "p50_ms": rank(50), "p95_ms": rank(95), "p99_ms": rank(99)})
        };
        let result = serde_json::json!({
            "schema_version":1, "status": if self.completed { "complete" } else { "incomplete" }, "reason":self.incomplete,
            "timestamp_unix_seconds":SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs(),
            "identity":self.identity, "system":self.system, "parameters":{"windows":self.options.windows,"seed":self.options.seed,"duration_seconds":self.options.duration,"warmup_seconds":self.options.warmup,"scenario":self.options.scenario,"reference_hz":self.options.target_hz,"reference_hz_source":"user/default threshold, not measured display refresh"},
            "environment":{"window_level_requested":"always_on_top","initial_activation_requested":true,"os":std::env::consts::OS,"arch":std::env::consts::ARCH,"adapter":self.adapter,"present_mode":self.present_mode,"physical_width":self.width,"physical_height":self.height,"scale_factor":self.scale,"display_refresh_hz":"unavailable","validation_flags":self.validation_flags,"device_limits":self.limits,"timestamp_query_supported":self.timestamp_supported,"timestamp_query_requested":gpu.requested,"timestamp_query_enabled":gpu.feature_enabled},
            "definitions":{"cadence":"time between returns from renderer, including atlas bookkeeping after present call; not physical display timing","cpu_times":"wall-clock durations of calls on render thread; submit/present are CPU call durations","draw_calls":"range: one geometry draw; text draw may be skipped by glyphon for empty glyphs","upload_bytes":"instance and viewport write_buffer bytes only; glyphon uploads unavailable","memory":"known buffers are instance and uniform only; depth texture bytes are logical width*height*4; glyphon resources, surface and driver allocations unavailable"},
            "unavailable":{"physical_present_latency_ms":"not measured","input_latency_ms":"not measured","cpu_usage":"not measured","rss":"not measured","allocations":"not measured","gpu_memory":"not measured"},
            "startup":{"first_render_completion_ms":self.startup_elapsed_ms,"occluded_acquisitions":self.startup_occluded,"deadline_seconds":10},"gpu_timing":{"scope":"elapsed GPU timestamp interval around canvas render pass; includes geometry and glyphon, may include preemption or overlap and is not exclusive GPU busy time; excludes uploads, resolve/copy, presentation and input latency", "report":gpu, "measurement_matched":gpu_values.len(), "measurement_frames":self.samples.len(), "measurement_coverage":if self.samples.is_empty() || !gpu.enabled { serde_json::json!("unavailable") } else { serde_json::json!(gpu_values.len() as f64 / self.samples.len() as f64) }, "statistics":gpu_stats,"statistics_unavailable_reason":gpu_reason},
            "retries":self.retries,"sample_limit":MAX_SAMPLES,"stage_ms_percentiles":stages,"statistics":stats(&intervals,self.options.target_hz).map_or_else(|| serde_json::json!("unavailable"), |value| serde_json::json!(value)),"last_frame":self.last_metrics.map_or_else(|| serde_json::json!("unavailable"), |frame| serde_json::json!(frame)),"raw_samples":self.samples,
        });
        let json = serde_json::to_vec_pretty(&result)?;
        if let Some(path) = &self.options.output {
            std::fs::write(path, &json).with_context(|| format!("writing {}", path.display()))?;
            println!("benchmark report: {}", path.display());
            if let Some(summary) = stats(&intervals, self.options.target_hz) {
                println!(
                    "{} samples; cadence p50/p95/p99 {:.3}/{:.3}/{:.3} ms; avg {:.2} FPS; median {:.2} FPS; 1% low {:.2} FPS; {} intervals > 1.5 reference periods",
                    summary.count,
                    summary.interval_ms_p50,
                    summary.interval_ms_p95,
                    summary.interval_ms_p99,
                    summary.average_fps,
                    summary.median_fps,
                    summary.one_percent_low_fps,
                    summary.long_intervals
                );
            } else {
                println!("cadence statistics unavailable: no valid samples");
            }
            if let Some(reason) = gpu_reason {
                println!(
                    "GPU render-pass interval unavailable: {reason}; coverage {}/{} frames",
                    gpu_values.len(),
                    self.samples.len()
                );
            } else {
                let n = gpu_values.len();
                let rank = |percent: usize| gpu_values[(n * percent).div_ceil(100) - 1];
                println!(
                    "GPU render-pass interval p50/p95/p99 {:.3}/{:.3}/{:.3} ms; coverage {}/{} frames",
                    rank(50),
                    rank(95),
                    rank(99),
                    n,
                    self.samples.len()
                );
            }
            if let Some(stages) = result["stage_ms_percentiles"].as_object() {
                for (name, values) in stages {
                    if let (Some(p50), Some(p95), Some(p99)) = (
                        values["p50"].as_f64(),
                        values["p95"].as_f64(),
                        values["p99"].as_f64(),
                    ) {
                        println!("{name}: p50/p95/p99 {p50:.3}/{p95:.3}/{p99:.3} ms");
                    }
                }
            }
        } else {
            println!("{}", String::from_utf8(json)?);
        }
        Ok(())
    }
}

fn densify(board: &mut Board, count: usize) -> Result<()> {
    let mut side = 1_usize;
    while side * side < count {
        side += 1;
    }
    let offset = f64::from(u32::try_from(side - 1)?) * 4.0;
    for index in 0..count {
        let id = WindowId(u64::try_from(index)?);
        let origin = board
            .scene
            .get(id)
            .context("demo window missing")?
            .bounds()
            .origin();
        let x = f64::from(u32::try_from(index % side)?).mul_add(8.0, -offset);
        let y = f64::from(u32::try_from(index / side)?).mul_add(8.0, -offset);
        board.scene.drag(id, x - origin.x(), y - origin.y())?;
    }
    Ok(())
}

pub fn microbench(options: &Options, mut board: Board) -> Result<()> {
    use std::hint::black_box;
    let viewport = desk_core::Viewport::new(1600, 1200, 2.0)?;
    board.resize(1600, 1200, 2.0);
    if options.scenario == Scenario::Dense {
        densify(&mut board, options.windows)?;
    }
    if options.scenario == Scenario::FitAll {
        anyhow::ensure!(board.fit_all(), "cannot fit scene");
    }
    let iterations = 100;
    let (cull, sort, prepare, visible) =
        desk_render::benchmark_prepare(&board.scene, board.camera, viewport, iterations)?;
    let hit = board
        .scene
        .windows()
        .first()
        .context("scene is empty")?
        .bounds()
        .origin();
    let miss = WorldPoint::new(900_000_000.0, 900_000_000.0)?;
    let mark = Instant::now();
    for _ in 0..iterations {
        black_box(black_box(&board.scene).hit_test(black_box(hit)));
    }
    let hit_ms = mark.elapsed().as_secs_f64() * 1000.0;
    let mark = Instant::now();
    for _ in 0..iterations {
        black_box(black_box(&board.scene).hit_test(black_box(miss)));
    }
    let miss_ms = mark.elapsed().as_secs_f64() * 1000.0;
    let result = serde_json::json!({"schema_version":1,"mode":"microbench","identity":identity()?,"parameters":{"windows":options.windows,"seed":options.seed,"scenario":options.scenario,"iterations":iterations,"viewport_physical":[1600,1200],"scale":2},"visible":visible,"elapsed_ms":{"cull":cull,"sort_visible_reverse_input":sort,"geometry_including_cull_and_sort":prepare,"hit_test_first_origin":hit_ms,"hit_test_miss":miss_ms},"unavailable":{"layout_churn":"requires GPU/text renderer instrumentation","allocations":"not measured"}});
    let bytes = serde_json::to_vec_pretty(&result)?;
    if let Some(path) = &options.output {
        std::fs::write(path, &bytes)?;
        println!("microbenchmark report: {}", path.display());
    } else {
        println!("{}", String::from_utf8(bytes)?);
    }
    Ok(())
}

fn trajectory(seconds: f64, zoom: f64) -> (f64, f64, f64, f64) {
    let (s, c) = (seconds * 0.35).sin_cos();
    (
        s * 250.0 / zoom,
        c * 150.0 / zoom,
        zoom * (0.2_f64.mul_add((seconds * 0.2).sin(), 1.0)),
        (seconds * 0.7).sin() * 50.0,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn known_statistics() {
        let Some(s) = stats(&[10.0, 20.0, 30.0, 40.0], 60) else {
            panic!("valid intervals")
        };
        assert_eq!(s.interval_ms_p50, 20.0);
        assert_eq!(s.interval_ms_p95, 40.0);
        assert_eq!(s.interval_ms_p99, 40.0);
        assert_eq!(s.average_fps, 40.0);
        assert_eq!(s.median_fps, 50.0);
        assert_eq!(s.one_percent_low_fps, 25.0);
        assert_eq!(s.long_intervals, 2);
        let Some(boundary) = stats(&[1000.0 / 60.0, 25.0, 25.001], 60) else {
            panic!("valid intervals")
        };
        assert_eq!(boundary.long_intervals, 1);
        let mut intervals = vec![10.0; 99];
        intervals.extend([20.0, 40.0]);
        let Some(tail) = stats(&intervals, 60) else {
            panic!("valid intervals")
        };
        assert!((tail.one_percent_low_fps - 1000.0 / 30.0).abs() < 1e-12);
        assert!(stats(&[], 60).is_none());
        assert!(stats(&[0.0], 60).is_none());
    }
    #[test]
    fn gpu_samples_join_by_frame_id_and_exclude_warmup() {
        let sample = |frame_id| Sample {
            elapsed_seconds: 1.0,
            interval_ms: 16.0,
            update_ms: 0.0,
            frame: FrameMetrics {
                frame_id,
                ..FrameMetrics::default()
            },
        };
        let gpu = [
            desk_render::GpuSample {
                frame_id: 9,
                render_pass_ms: 5.0,
            },
            desk_render::GpuSample {
                frame_id: 2,
                render_pass_ms: 99.0,
            },
            desk_render::GpuSample {
                frame_id: 5,
                render_pass_ms: 3.0,
            },
        ];
        assert_eq!(
            gpu_measurement_values(&[sample(5), sample(9)], &gpu),
            [3.0, 5.0]
        );
        assert_eq!(gpu_measurement_values(&[], &gpu), [] as [f64; 0]);
    }
    #[test]
    fn gpu_percentiles_require_complete_trustworthy_coverage() {
        let mut report = GpuReport::unavailable(true, true, "test");
        assert!(gpu_statistics_unavailable_reason(&report, 2, 2, true).is_some());
        report.enabled = true;
        assert_eq!(gpu_statistics_unavailable_reason(&report, 2, 2, true), None);
        assert!(gpu_statistics_unavailable_reason(&report, 2, 2, false).is_some());
        assert!(gpu_statistics_unavailable_reason(&report, 2, 1, true).is_some());
        report.invalid_timestamps_total = 1;
        assert!(gpu_statistics_unavailable_reason(&report, 2, 2, true).is_some());
        report.invalid_timestamps_total = 0;
        report.pending_at_drain_end = 1;
        assert!(gpu_statistics_unavailable_reason(&report, 2, 2, true).is_some());
    }
    #[test]
    fn warmup_cadence_excludes_boundary_interval() -> Result<()> {
        let options = match crate::cli::parse(
            ["--benchmark", "--warmup", "1", "--duration", "2"]
                .into_iter()
                .map(std::ffi::OsString::from),
        )
        .map_err(anyhow::Error::msg)?
        {
            crate::cli::Command::Run(options) => options,
            crate::cli::Command::Help => anyhow::bail!("unexpected help"),
        };
        let start = Instant::now();
        let mut bench = Benchmark {
            options,
            identity: Identity {
                commit: None,
                source_sha256: String::new(),
                binary_sha256: String::new(),
                source_dirty: false,
                source_hash_scope: "test",
            },
            system: system_info(),
            start,
            deadline: start + Duration::from_secs(8),
            started: true,
            startup_elapsed_ms: None,
            startup_occluded: 0,
            previous: None,
            samples: Vec::new(),
            completed: false,
            incomplete: None,
            retries: 0,
            last_metrics: None,
            adapter: String::new(),
            present_mode: String::new(),
            validation_flags: String::new(),
            limits: String::new(),
            timestamp_supported: false,
            width: 800,
            height: 600,
            scale: 1.0,
            base_camera: Camera::new(WorldPoint::new(0.0, 0.0)?, 1.0)?,
            origins: Vec::new(),
        };
        bench.started = false;
        bench.startup_occluded();
        let first = start + Duration::from_secs(5);
        bench.first_frame_completed(first);
        assert!(bench.started);
        assert_eq!(bench.startup_occluded, 1);
        assert_eq!(bench.deadline, first + Duration::from_secs(8));
        assert_eq!(bench.startup_elapsed_ms, Some(5000.0));
        bench.first_frame_completed(first + Duration::from_millis(1));
        assert_eq!(bench.start, first);
        let frame = FrameMetrics::default();
        bench.record(first + Duration::from_millis(990), 0.0, frame);
        bench.record(first + Duration::from_millis(1002), 0.0, frame);
        assert!(bench.samples.is_empty());
        bench.record(first + Duration::from_millis(1018), 0.0, frame);
        assert_eq!(bench.samples.len(), 1);
        assert!((bench.samples[0].interval_ms - 16.0).abs() < 1e-9);
        Ok(())
    }
    #[test]
    fn trajectory_replay_is_frame_rate_independent() -> Result<()> {
        let options = match crate::cli::parse(
            ["--benchmark", "--windows", "100"]
                .into_iter()
                .map(std::ffi::OsString::from),
        )
        .map_err(anyhow::Error::msg)?
        {
            crate::cli::Command::Run(options) => options,
            crate::cli::Command::Help => anyhow::bail!("unexpected help"),
        };
        let scene = crate::interaction::clustered_demo(100, 42)?;
        let camera = Camera::new(WorldPoint::new(0.0, 0.0)?, 1.0)?;
        let mut a = Board::new(scene.clone(), camera, None);
        let mut b = Board::new(scene, camera, None);
        a.resize(800, 600, 1.0);
        b.resize(800, 600, 1.0);
        let start = Instant::now();
        let origins = a
            .scene
            .windows()
            .iter()
            .take(3)
            .map(|w| (w.id(), w.bounds().origin()))
            .collect();
        let benchmark = Benchmark {
            options,
            identity: Identity {
                commit: None,
                source_sha256: String::new(),
                binary_sha256: String::new(),
                source_dirty: false,
                source_hash_scope: "test",
            },
            system: system_info(),
            start,
            deadline: start + Duration::from_secs(10),
            started: true,
            startup_elapsed_ms: None,
            startup_occluded: 0,
            previous: None,
            samples: Vec::new(),
            completed: false,
            incomplete: None,
            retries: 0,
            last_metrics: None,
            adapter: String::new(),
            present_mode: String::new(),
            validation_flags: String::new(),
            limits: String::new(),
            timestamp_supported: false,
            width: 800,
            height: 600,
            scale: 1.0,
            base_camera: camera,
            origins,
        };
        for frame in 1..=60 {
            benchmark.update(
                &mut a,
                start + Duration::from_secs_f64(f64::from(frame) / 60.0),
            )?;
        }
        for frame in 1..=120 {
            benchmark.update(
                &mut b,
                start + Duration::from_secs_f64(f64::from(frame) / 120.0),
            )?;
        }
        assert_eq!(a.camera, b.camera);
        for id in 0..3 {
            let x = a
                .scene
                .get(WindowId(id))
                .context("missing a")?
                .bounds()
                .origin()
                .x();
            let y = b
                .scene
                .get(WindowId(id))
                .context("missing b")?
                .bounds()
                .origin()
                .x();
            assert!((x - y).abs() < 1e-8);
        }
        Ok(())
    }
}
