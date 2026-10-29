use std::{
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context, Result};
use desk_core::{Camera, Scene, WindowId, WorldPoint};
use desk_render::{FrameOutcome, Renderer};
use winit::{
    application::ApplicationHandler,
    event::WindowEvent,
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy},
    window::{Window, WindowId as NativeWindowId},
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
    scene: Scene,
    camera: Camera,
    selected: Option<WindowId>,
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
            let window = Arc::new(
                event_loop
                    .create_window(Window::default_attributes().with_title("InfiniteDesk"))?,
            );
            let proxy = self.proxy.clone();
            let mut renderer = pollster::block_on(Renderer::new(
                Arc::clone(&window),
                Arc::new(move |message| {
                    let _ = proxy.send_event(GpuError(message));
                }),
            ))?;
            renderer.prewarm(&self.scene, self.camera, self.selected)?;
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
        match event {
            WindowEvent::CloseRequested => event_loop.exit(),
            WindowEvent::Resized(size) => {
                self.retry.reset();
                event_loop.set_control_flow(ControlFlow::Wait);
                renderer.resize(size);
                window.request_redraw();
            }
            WindowEvent::Occluded(false) | WindowEvent::ScaleFactorChanged { .. } => {
                window.request_redraw();
            }
            WindowEvent::RedrawRequested => {
                match renderer.render(&self.scene, self.camera, self.selected) {
                    Ok(FrameOutcome::Retry) => {
                        let deadline = self.retry.schedule(Instant::now());
                        event_loop.set_control_flow(ControlFlow::WaitUntil(deadline));
                    }
                    Ok(FrameOutcome::Presented | FrameOutcome::Occluded) => {
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
    }
    fn user_event(&mut self, event_loop: &ActiveEventLoop, error: GpuError) {
        self.error = Some(anyhow::anyhow!(error.0));
        event_loop.exit();
    }

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        if self.retry.take_due(Instant::now()) {
            event_loop.set_control_flow(ControlFlow::Wait);
            if let Some(window) = &self.window {
                window.request_redraw();
            }
        }
    }
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    let event_loop = EventLoop::<GpuError>::with_user_event()
        .build()
        .context("failed to create event loop")?;
    let mut scene = Scene::demo(1000, 42)?;
    for index in 0_u64..12 {
        let id = WindowId(index);
        let window = scene.get(id).context("demo window missing")?;
        let origin = window.bounds().origin();
        let x = if index == 2 {
            -190.0
        } else {
            f64::from(u32::try_from(index % 4)?).mul_add(245.0, -470.0)
        };
        let y = if index == 2 {
            -285.0
        } else {
            f64::from(u32::try_from(index / 4)?).mul_add(190.0, -300.0)
        };
        scene.drag(id, x - origin.x(), y - origin.y())?;
    }
    let camera = Camera::new(WorldPoint::new(0.0, 0.0)?, 1.0)?;
    let mut app = App {
        scene,
        camera,
        selected: Some(WindowId(11)),
        proxy: event_loop.create_proxy(),
        retry: RetryState::default(),
        window: None,
        renderer: None,
        error: None,
    };
    event_loop.run_app(&mut app).context("event loop failed")?;
    if let Some(error) = app.error {
        return Err(error);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

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
