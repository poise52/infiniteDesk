use std::sync::Arc;

use thiserror::Error;
use winit::{dpi::PhysicalSize, window::Window};

#[derive(Debug, Error)]
pub enum RenderError {
    #[error("failed to create GPU surface: {0}")]
    Surface(#[from] wgpu::CreateSurfaceError),
    #[error("failed to select GPU adapter: {0}")]
    Adapter(#[from] wgpu::RequestAdapterError),
    #[error("failed to create GPU device: {0}")]
    Device(#[from] wgpu::RequestDeviceError),
    #[error("surface has no supported default configuration")]
    SurfaceConfiguration,
    #[error("GPU surface failed: {0}")]
    Frame(&'static str),
}

#[derive(Debug, Clone, Copy)]
pub enum FrameOutcome {
    Presented,
    Retry,
    Occluded,
}

#[derive(Debug)]
pub struct Renderer {
    surface: wgpu::Surface<'static>,
    instance: wgpu::Instance,
    window: Arc<Window>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    size: PhysicalSize<u32>,
}

impl Renderer {
    /// Creates a renderer for a window. The surface retains the window while it exists.
    ///
    /// # Errors
    /// Returns an error if the surface, adapter, device, or surface configuration is unavailable.
    pub async fn new(
        window: Arc<Window>,
        on_gpu_error: Arc<dyn Fn(String) + Send + Sync>,
    ) -> Result<Self, RenderError> {
        let size = window.inner_size();
        let mut descriptor = wgpu::InstanceDescriptor::new_without_display_handle();
        descriptor.backends = wgpu::Backends::METAL;
        let instance = wgpu::Instance::new(descriptor);
        let surface = instance.create_surface(Arc::clone(&window))?;
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                compatible_surface: Some(&surface),
                ..Default::default()
            })
            .await?;
        tracing::info!(adapter = ?adapter.get_info(), "selected GPU adapter");
        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor::default())
            .await?;
        let on_uncaptured = Arc::clone(&on_gpu_error);
        device.on_uncaptured_error(Arc::new(move |error| {
            on_uncaptured(format!("GPU error: {error}"));
        }));
        device.set_device_lost_callback(move |reason, message| {
            on_gpu_error(format!("GPU device lost ({reason:?}): {message}"));
        });
        let config = surface
            .get_default_config(&adapter, size.width.max(1), size.height.max(1))
            .ok_or(RenderError::SurfaceConfiguration)?;
        let mut renderer = Self {
            surface,
            instance,
            window,
            device,
            queue,
            config,
            size,
        };
        renderer.configure();
        Ok(renderer)
    }

    fn configure(&mut self) {
        if self.size.width > 0 && self.size.height > 0 {
            self.config.width = self.size.width;
            self.config.height = self.size.height;
            self.surface.configure(&self.device, &self.config);
        }
    }

    pub fn resize(&mut self, size: PhysicalSize<u32>) {
        self.size = size;
        self.configure();
    }

    /// Clears and presents the surface if it has a drawable size.
    ///
    /// # Errors
    /// Returns an error when the surface reports an unrecoverable frame failure.
    pub fn render(&mut self) -> Result<FrameOutcome, RenderError> {
        if self.size.width == 0 || self.size.height == 0 {
            return Ok(FrameOutcome::Occluded);
        }
        let (frame, suboptimal) = match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(frame) => (frame, false),
            wgpu::CurrentSurfaceTexture::Suboptimal(frame) => (frame, true),
            wgpu::CurrentSurfaceTexture::Timeout => return Ok(FrameOutcome::Retry),
            wgpu::CurrentSurfaceTexture::Occluded => return Ok(FrameOutcome::Occluded),
            wgpu::CurrentSurfaceTexture::Outdated => {
                self.configure();
                return Ok(FrameOutcome::Retry);
            }
            wgpu::CurrentSurfaceTexture::Lost => {
                self.surface = self.instance.create_surface(Arc::clone(&self.window))?;
                self.configure();
                return Ok(FrameOutcome::Retry);
            }
            wgpu::CurrentSurfaceTexture::Validation => {
                return Err(RenderError::Frame("validation error"));
            }
        };
        let view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("clear encoder"),
            });
        {
            let _pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("clear pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: 0.025,
                            g: 0.035,
                            b: 0.055,
                            a: 1.0,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                    depth_slice: None,
                })],
                ..Default::default()
            });
        }
        self.queue.submit([encoder.finish()]);
        self.queue.present(frame);
        drop(view);
        if suboptimal {
            self.configure();
        }
        Ok(if suboptimal {
            FrameOutcome::Retry
        } else {
            FrameOutcome::Presented
        })
    }
}
