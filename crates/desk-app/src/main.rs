use std::{
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context, Result};
mod benchmark;
#[cfg(all(target_os = "macos", feature = "native-browser"))]
#[allow(unsafe_code)]
mod browser;
mod cli;
mod interaction;

use desk_core::{Camera, PhysicalPoint, WindowId, WorldPoint};
use desk_render::{FrameOutcome, Renderer};
use interaction::Board;
use winit::{
    application::ApplicationHandler,
    event::{ElementState, MouseButton, MouseScrollDelta, TouchPhase, WindowEvent},
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy},
    keyboard::{KeyCode, ModifiersState, PhysicalKey},
    window::{Window, WindowAttributes, WindowId as NativeWindowId, WindowLevel},
};

#[derive(Debug)]
struct RetryState {
    deadline: Option<Instant>,
    delay: Duration,
}

impl Default for RetryState {
    fn default() -> Self {
        Self {
            deadline: None,
            delay: Duration::from_millis(16),
        }
    }
}

impl RetryState {
    fn schedule(&mut self, now: Instant) -> Instant {
        let deadline = now + self.delay;
        self.deadline = Some(deadline);
        self.delay = (self.delay * 2).min(Duration::from_secs(1));
        deadline
    }

    fn reset(&mut self) {
        *self = Self::default();
    }

    fn take_due(&mut self, now: Instant) -> bool {
        if self.deadline.is_some_and(|deadline| now >= deadline) {
            self.deadline = None;
            true
        } else {
            false
        }
    }
}

#[derive(Debug)]
struct GpuError(String);

struct App {
    board: Board,
    #[cfg(all(target_os = "macos", feature = "native-browser"))]
    browser_mode: browser::Mode,
    #[cfg(all(target_os = "macos", feature = "native-browser"))]
    browsers: Vec<browser::Browser>,
    startup_focus: bool,
    benchmark_options: Option<cli::Options>,
    benchmark: Option<benchmark::Benchmark>,
    space: bool,
    modifiers: ModifiersState,
    pointer_button: Option<MouseButton>,
    occluded: bool,
    proxy: EventLoopProxy<GpuError>,
    retry: RetryState,
    window: Option<Arc<Window>>,
    renderer: Option<Renderer>,
    error: Option<anyhow::Error>,
}

impl ApplicationHandler<GpuError> for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }
        let result = (|| -> Result<_> {
            let attributes = window_attributes(self.benchmark_options.is_some());
            #[cfg(all(target_os = "macos", feature = "native-browser"))]
            let attributes = if self.browser_mode == browser::Mode::Browser {
                attributes.with_inner_size(winit::dpi::LogicalSize::new(1200.0, 800.0))
            } else {
                attributes
            };
            let window = Arc::new(event_loop.create_window(attributes)?);
            let proxy = self.proxy.clone();
            let mut renderer = pollster::block_on(Renderer::new(
                Arc::clone(&window),
                Arc::new(move |message| {
                    let _ = proxy.send_event(GpuError(message));
                }),
                self.benchmark_options
                    .as_ref()
                    .is_some_and(|options| options.gpu_timestamps),
            ))?;
            let size = window.inner_size();
            self.board
                .resize(size.width, size.height, window.scale_factor());
            if self.startup_focus && !self.board.focus_selected() {
                anyhow::bail!("unable to focus the requested window in the initial viewport");
            }
            if let Some(options) = self.benchmark_options.take() {
                renderer.enable_metrics();
                self.benchmark = Some(benchmark::Benchmark::new(
                    options,
                    &mut self.board,
                    size.width,
                    size.height,
                    window.scale_factor(),
                    renderer.adapter_info().to_owned(),
                    format!("{:?}", renderer.present_mode()),
                    renderer.validation_flags().to_owned(),
                    renderer.device_limits().to_owned(),
                    renderer.timestamp_supported(),
                )?);
            }
            renderer.prewarm(&self.board.scene, self.board.camera, self.board.selected)?;
            if let Some(benchmark) = &mut self.benchmark {
                benchmark.begin_after_init();
            }
            #[cfg(all(target_os = "macos", feature = "native-browser"))]
            if self.browser_mode == browser::Mode::Browser {
                self.board.fit_all();
                for id in 0..browser::INITIAL_CARDS {
                    self.browsers
                        .push(browser::Browser::new(Arc::clone(&window), WindowId(id))?);
                }
            }
            Ok((window, renderer))
        })();
        match result {
            Ok((window, renderer)) => {
                window.request_redraw();
                self.window = Some(window);
                self.renderer = Some(renderer);
            }
            Err(error) => {
                self.error = Some(error.context("failed to initialize application"));
                event_loop.exit();
            }
        }
    }

    #[allow(clippy::too_many_lines)]
    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        id: NativeWindowId,
        event: WindowEvent,
    ) {
        let (Some(window), Some(renderer)) = (&self.window, &mut self.renderer) else {
            return;
        };
        if window.id() != id {
            return;
        }
        let now = Instant::now();
        let mut redraw = false;
        if self.benchmark.is_some()
            && matches!(
                event,
                WindowEvent::CursorMoved { .. }
                    | WindowEvent::CursorLeft { .. }
                    | WindowEvent::MouseInput { .. }
                    | WindowEvent::MouseWheel { .. }
                    | WindowEvent::PinchGesture { .. }
                    | WindowEvent::KeyboardInput { .. }
            )
        {
            return;
        }
        match event {
            WindowEvent::CloseRequested => {
                #[cfg(all(target_os = "macos", feature = "native-browser"))]
                {
                    self.browsers.clear();
                }
                if let Some(benchmark) = &mut self.benchmark {
                    benchmark.incomplete = Some("window closed before completion".into());
                }
                event_loop.exit();
            }
            WindowEvent::Resized(size) => {
                if let Some(benchmark) = &mut self.benchmark
                    && (size.width == 0 || size.height == 0)
                {
                    benchmark.incomplete = Some("window minimized or zero viewport".into());
                    event_loop.exit();
                    return;
                }
                if let Some(benchmark) = &mut self.benchmark
                    && size.width > 0
                    && size.height > 0
                    && !benchmark.viewport_matches(size.width, size.height, window.scale_factor())
                {
                    benchmark.incomplete = Some("viewport changed during benchmark".into());
                    event_loop.exit();
                    return;
                }
                self.board
                    .resize(size.width, size.height, window.scale_factor());
                self.pointer_button = None;
                self.occluded = !self.board.has_viewport();
                self.retry.reset();
                event_loop.set_control_flow(ControlFlow::Wait);
                renderer.resize(size);
                redraw = !self.occluded;
            }
            WindowEvent::ScaleFactorChanged { .. } => {
                let size = window.inner_size();
                if let Some(benchmark) = &mut self.benchmark
                    && size.width > 0
                    && size.height > 0
                    && !benchmark.viewport_matches(size.width, size.height, window.scale_factor())
                {
                    benchmark.incomplete = Some("viewport scale changed during benchmark".into());
                    event_loop.exit();
                    return;
                }
                self.board
                    .resize(size.width, size.height, window.scale_factor());
                self.pointer_button = None;
                self.occluded = !self.board.has_viewport();
                redraw = !self.occluded;
            }
            WindowEvent::Focused(false) => {
                self.board.cursor_left();
                self.space = false;
                self.pointer_button = None;
                self.modifiers = ModifiersState::empty();
            }
            WindowEvent::CursorLeft { .. } => {
                self.board.cursor_left();
                self.pointer_button = None;
            }
            WindowEvent::CursorMoved { position, .. } => {
                redraw = self.board.cursor_moved(
                    PhysicalPoint {
                        x: position.x,
                        y: position.y,
                    },
                    now,
                );
            }
            WindowEvent::ModifiersChanged(modifiers) => self.modifiers = modifiers.state(),
            WindowEvent::MouseInput {
                state: ElementState::Pressed,
                button,
                ..
            } => {
                if self.pointer_button.is_none() {
                    match button {
                        MouseButton::Middle => {
                            self.board.start_pan(now);
                            self.pointer_button = Some(button);
                        }
                        MouseButton::Left if self.space => {
                            self.board.start_pan(now);
                            self.pointer_button = Some(button);
                        }
                        MouseButton::Left => {
                            redraw = self.board.start_select();
                            self.pointer_button = Some(button);
                        }
                        _ => {}
                    }
                }
            }
            WindowEvent::MouseInput {
                state: ElementState::Released,
                button,
                ..
            } => {
                redraw = release_pointer(&mut self.board, &mut self.pointer_button, button, now);
            }
            WindowEvent::MouseWheel { delta, phase, .. } => {
                if phase == TouchPhase::Cancelled {
                    self.board.cancel();
                    self.pointer_button = None;
                } else {
                    let (dx, dy) = match delta {
                        MouseScrollDelta::LineDelta(x, y) => {
                            (f64::from(x) * 40.0, f64::from(y) * 40.0)
                        }
                        MouseScrollDelta::PixelDelta(p) => {
                            (p.x / window.scale_factor(), p.y / window.scale_factor())
                        }
                    };
                    self.pointer_button = None;
                    redraw = if self.modifiers.control_key() || self.modifiers.super_key() {
                        self.board.zoom((dy * 0.002).exp())
                    } else {
                        self.board.wheel_pan(dx, dy)
                    };
                }
            }
            WindowEvent::PinchGesture { delta, phase, .. } => {
                self.pointer_button = None;
                if phase == TouchPhase::Cancelled {
                    self.board.cancel();
                } else {
                    redraw = self.board.zoom(1.0 + delta);
                }
            }
            WindowEvent::KeyboardInput { event, .. } => {
                if let PhysicalKey::Code(key) = event.physical_key {
                    if key == KeyCode::Space {
                        self.space = event.state == ElementState::Pressed;
                    } else if event.state == ElementState::Pressed
                        && !event.repeat
                        && key == KeyCode::Enter
                        && self.modifiers.super_key()
                    {
                        #[cfg(all(target_os = "macos", feature = "native-browser"))]
                        let browser_mode = self.browser_mode == browser::Mode::Browser;
                        #[cfg(not(all(target_os = "macos", feature = "native-browser")))]
                        let browser_mode = false;
                        if browser_mode {
                            #[cfg(all(target_os = "macos", feature = "native-browser"))]
                            for browser in &self.browsers {
                                browser.open_selected(self.board.selected);
                            }
                        } else {
                            redraw = self.board.focus_selected();
                            self.pointer_button = None;
                        }
                    } else if event.state == ElementState::Pressed
                        && !event.repeat
                        && key == KeyCode::KeyN
                    {
                        #[cfg(all(target_os = "macos", feature = "native-browser"))]
                        if self.browser_mode == browser::Mode::Browser {
                            match browser::add_card(
                                &mut self.board,
                                &mut self.browsers,
                                Arc::clone(window),
                            ) {
                                Ok(changed) => {
                                    if changed {
                                        self.pointer_button = None;
                                    }
                                    redraw = changed;
                                }
                                Err(error) => tracing::error!(%error, "failed to add card"),
                            }
                        }
                    } else if event.state == ElementState::Pressed
                        && !event.repeat
                        && let Some(changed) = route_key(
                            &mut self.board,
                            &mut self.pointer_button,
                            key,
                            self.modifiers,
                        )
                    {
                        redraw = changed;
                    }
                }
            }
            WindowEvent::Occluded(true) => {
                if let Some(benchmark) = &mut self.benchmark {
                    if benchmark.started {
                        benchmark.incomplete = Some("window occluded during benchmark".into());
                        event_loop.exit();
                    }
                    return;
                }
                self.occluded = true;
                self.board.cancel();
                self.pointer_button = None;
            }
            WindowEvent::Occluded(false) => {
                self.occluded = !self.board.has_viewport();
                self.retry.reset();
                event_loop.set_control_flow(ControlFlow::Wait);
                redraw = true;
            }
            WindowEvent::RedrawRequested if !self.occluded && self.retry.deadline.is_none() => {
                let update_ms = if let Some(benchmark) = &mut self.benchmark {
                    match benchmark.update(&mut self.board, now) {
                        Ok(ms) => ms,
                        Err(error) => {
                            benchmark.incomplete = Some(format!("scenario update failed: {error}"));
                            event_loop.exit();
                            return;
                        }
                    }
                } else {
                    self.board.tick(now);
                    0.0
                };
                #[cfg(all(target_os = "macos", feature = "native-browser"))]
                for browser in &mut self.browsers {
                    browser.update(&self.board);
                }
                match renderer.render(&self.board.scene, self.board.camera, self.board.selected) {
                    Ok(FrameOutcome::Retry) => {
                        if let Some(benchmark) = &mut self.benchmark {
                            benchmark.retry();
                        }
                        let deadline = self.retry.schedule(Instant::now());
                        event_loop.set_control_flow(ControlFlow::WaitUntil(deadline));
                    }
                    Ok(FrameOutcome::Presented) => {
                        self.retry.reset();
                        event_loop.set_control_flow(ControlFlow::Wait);
                        if let Some(benchmark) = &mut self.benchmark {
                            let completed_at = Instant::now();
                            benchmark.first_frame_completed(completed_at);
                            benchmark.record(completed_at, update_ms, renderer.metrics());
                            if benchmark.completed || benchmark.incomplete.is_some() {
                                event_loop.exit();
                            } else {
                                redraw = true;
                            }
                        } else {
                            redraw = self.board.inertia_active();
                        }
                    }
                    Ok(FrameOutcome::Occluded) => {
                        if let Some(benchmark) = &mut self.benchmark {
                            if benchmark.started {
                                benchmark.incomplete =
                                    Some("surface occluded during benchmark".into());
                                event_loop.exit();
                            } else {
                                benchmark.startup_occluded();
                                benchmark.retry();
                                let deadline = self.retry.schedule(Instant::now());
                                event_loop.set_control_flow(ControlFlow::WaitUntil(deadline));
                            }
                            return;
                        }
                        self.board.cancel();
                        self.occluded = true;
                        self.retry.reset();
                        event_loop.set_control_flow(ControlFlow::Wait);
                    }
                    Err(error) => {
                        self.error =
                            Some(anyhow::Error::new(error).context("failed to render frame"));
                        event_loop.exit();
                    }
                }
            }
            _ => {}
        }
        if redraw && !self.occluded && self.retry.deadline.is_none() {
            window.request_redraw();
        }
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, error: GpuError) {
        self.error = Some(anyhow::anyhow!(error.0));
        event_loop.exit();
    }

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        let now = Instant::now();
        if let Some(benchmark) = &mut self.benchmark
            && now >= benchmark.deadline
        {
            benchmark.incomplete = Some(
                "deadline reached before completion (window occluded or frame acquisition stalled)"
                    .into(),
            );
            event_loop.exit();
            return;
        }
        if self.retry.take_due(now)
            && let Some(window) = &self.window
        {
            window.request_redraw();
        }
        let deadline = match (
            self.retry.deadline,
            self.benchmark.as_ref().map(|b| b.deadline),
        ) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (Some(a), None) | (None, Some(a)) => Some(a),
            (None, None) => None,
        };
        event_loop.set_control_flow(deadline.map_or(ControlFlow::Wait, ControlFlow::WaitUntil));
    }
}

fn window_attributes(benchmark: bool) -> WindowAttributes {
    let attributes = Window::default_attributes().with_title("InfiniteDesk");
    if benchmark {
        attributes
            .with_window_level(WindowLevel::AlwaysOnTop)
            .with_active(true)
    } else {
        attributes
    }
}

fn route_key(
    board: &mut Board,
    pointer: &mut Option<MouseButton>,
    key: KeyCode,
    modifiers: ModifiersState,
) -> Option<bool> {
    let changed = match key {
        KeyCode::KeyR => board.reset(),
        KeyCode::KeyF => board.fit_all(),
        KeyCode::Enter => board.focus_selected(),
        KeyCode::Tab => board.cycle(modifiers.shift_key()),
        KeyCode::Escape => {
            board.cancel();
            false
        }
        _ => return None,
    };
    *pointer = None;
    Some(changed)
}

fn release_pointer(
    board: &mut Board,
    pointer: &mut Option<MouseButton>,
    button: MouseButton,
    now: Instant,
) -> bool {
    if *pointer == Some(button) {
        *pointer = None;
        board.release(now)
    } else {
        false
    }
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    #[cfg(all(target_os = "macos", feature = "native-browser"))]
    let browser_mode = args.is_empty() && browser::is_bundle_demo();
    let options = match cli::parse(args).map_err(anyhow::Error::msg)? {
        cli::Command::Help => {
            print!("{}", cli::HELP);
            return Ok(());
        }
        cli::Command::Run(options) => options,
    };
    #[cfg(all(target_os = "macos", feature = "native-browser"))]
    let scene = if browser_mode {
        browser::scene()?
    } else {
        interaction::clustered_demo(options.windows, options.seed)?
    };
    #[cfg(not(all(target_os = "macos", feature = "native-browser")))]
    let scene = interaction::clustered_demo(options.windows, options.seed)?;
    let camera = Camera::new(WorldPoint::new(0.0, 0.0)?, 1.0)?;
    #[cfg(all(target_os = "macos", feature = "native-browser"))]
    let selected = if browser_mode {
        0
    } else {
        options.focus.unwrap_or(11)
    };
    #[cfg(not(all(target_os = "macos", feature = "native-browser")))]
    let selected = options.focus.unwrap_or(11);
    let board = Board::new(scene, camera, Some(WindowId(selected)));
    if options.mode == cli::Mode::Microbench {
        return benchmark::microbench(&options, board);
    }
    let event_loop = EventLoop::<GpuError>::with_user_event()
        .build()
        .context("failed to create event loop")?;
    let mut app = App {
        board,
        #[cfg(all(target_os = "macos", feature = "native-browser"))]
        browser_mode: if browser_mode {
            browser::Mode::Browser
        } else {
            browser::Mode::Board
        },
        #[cfg(all(target_os = "macos", feature = "native-browser"))]
        browsers: Vec::new(),
        startup_focus: options.focus.is_some(),
        benchmark_options: (options.mode == cli::Mode::Benchmark).then_some(options),
        benchmark: None,
        space: false,
        modifiers: ModifiersState::empty(),
        pointer_button: None,
        occluded: false,
        proxy: event_loop.create_proxy(),
        retry: RetryState::default(),
        window: None,
        renderer: None,
        error: None,
    };
    if let Err(error) = event_loop.run_app(&mut app) {
        app.error = Some(anyhow::Error::new(error).context("event loop failed"));
    }
    if let Some(benchmark) = &mut app.benchmark {
        if app.error.is_some() && benchmark.incomplete.is_none() {
            benchmark.incomplete = Some("render failed".into());
        }
        let gpu = app.renderer.as_mut().map_or_else(
            || desk_render::GpuReport::unavailable(false, false, "renderer unavailable"),
            desk_render::Renderer::finish_gpu_timing,
        );
        benchmark.finish(&gpu)?;
        if !benchmark.completed {
            anyhow::bail!(
                "benchmark incomplete: {}",
                benchmark.incomplete.as_deref().unwrap_or("unknown reason")
            );
        }
    }
    if let Some(error) = app.error {
        return Err(error);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn benchmark_window_requests_floating_active_without_changing_demo_level() {
        let demo = window_attributes(false);
        let bench = window_attributes(true);
        assert_eq!(demo.window_level, WindowLevel::Normal);
        assert_eq!(bench.window_level, WindowLevel::AlwaysOnTop);
        assert!(bench.active);
    }

    #[test]
    fn unknown_key_preserves_pointer_release_and_ends_drag() -> Result<(), desk_core::GeometryError>
    {
        let mut scene = desk_core::Scene::default();
        let bounds = desk_core::WorldRect::new(WorldPoint::new(-50.0, -50.0)?, 100.0, 100.0)?;
        scene.add(desk_core::Window::new(
            WindowId(1),
            "test".into(),
            bounds,
            [0, 0, 0, 255],
            0,
        ))?;
        let mut board = Board::new(scene, Camera::new(WorldPoint::new(0.0, 0.0)?, 1.0)?, None);
        board.resize(800, 600, 1.0);
        let now = Instant::now();
        board.cursor_moved(PhysicalPoint { x: 400.0, y: 300.0 }, now);
        assert!(board.start_select());
        let mut pointer = Some(MouseButton::Left);
        assert_eq!(
            route_key(
                &mut board,
                &mut pointer,
                KeyCode::KeyA,
                ModifiersState::empty()
            ),
            None
        );
        assert_eq!(pointer, Some(MouseButton::Left));
        release_pointer(&mut board, &mut pointer, MouseButton::Left, now);
        assert!(!board.cursor_moved(PhysicalPoint { x: 420.0, y: 320.0 }, now));
        assert_eq!(
            board
                .scene
                .get(WindowId(1))
                .ok_or(desk_core::GeometryError::UnknownWindow)?
                .bounds()
                .origin(),
            WorldPoint::new(-50.0, -50.0)?
        );
        Ok(())
    }

    #[test]
    fn retry_backoff_is_bounded_and_reset_cancels_pending_retry() {
        let now = Instant::now();
        let mut retry = RetryState::default();
        let first = retry.schedule(now);
        assert!(!retry.take_due(now));
        assert!(retry.take_due(first));
        assert!(!retry.take_due(first));
        let second = retry.schedule(now);
        assert!(second > first);
        for _ in 0..20 {
            retry.schedule(now);
        }
        assert_eq!(retry.schedule(now) - now, Duration::from_secs(1));
        retry.reset();
        assert!(!retry.take_due(now + Duration::from_secs(2)));
        assert_eq!(retry.schedule(now), first);
    }
}
