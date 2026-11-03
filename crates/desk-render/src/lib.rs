mod gpu_timing;
mod prepare;

pub use gpu_timing::{GpuReport, GpuSample};

use desk_core::{Camera, Scene, Viewport, WindowId};
use glyphon::{
    Attrs, Buffer, Cache, Color, Family, FontSystem, Metrics, Resolution, Shaping, SwashCache,
    TextArea, TextAtlas, TextBounds, TextRenderer,
};
use prepare::{Instance, Label};
use std::{collections::HashMap, sync::Arc, time::Instant};
use thiserror::Error;
use wgpu::util::DeviceExt;
use winit::{dpi::PhysicalSize, window::Window};

#[derive(Debug, Error)]
pub enum RenderError {
    #[error("failed to create GPU surface: {0}")]
    Surface(#[from] wgpu::CreateSurfaceError),
    #[error("failed to select GPU adapter: {0}")]
    Adapter(#[from] wgpu::RequestAdapterError),
    #[error("failed to create GPU device: {0}")]
    Device(#[from] wgpu::RequestDeviceError),
    #[error("failed to create GPU device with requested timestamp queries: {0}")]
    TimestampDevice(wgpu::RequestDeviceError),
    #[error("surface has no supported default configuration")]
    SurfaceConfiguration,
    #[error("GPU surface failed: {0}")]
    Frame(&'static str),
    #[error("invalid canvas geometry: {0}")]
    Geometry(#[from] desk_core::GeometryError),
    #[error("failed to prepare text: {0}")]
    TextPrepare(#[from] glyphon::PrepareError),
    #[error("failed to render text: {0}")]
    TextRender(#[from] glyphon::RenderError),
    #[error("too many render instances")]
    Capacity,
}

#[derive(Debug, Clone, Copy)]
pub enum FrameOutcome {
    Presented,
    Retry,
    Occluded,
}

#[derive(Debug, Clone, Copy, Default, serde::Serialize)]
pub struct FrameMetrics {
    pub frame_id: u64,
    pub gpu_poll_ms: Option<f64>,
    pub acquire_ms: f64,
    pub geometry_ms: f64,
    pub upload_ms: f64,
    pub text_ms: f64,
    pub encode_ms: f64,
    pub submit_ms: f64,
    pub present_call_ms: f64,
    pub visible: usize,
    pub primitives: usize,
    pub labels: usize,
    pub layout_hits: usize,
    pub layout_misses: usize,
    pub retained_layouts: usize,
    pub raster_cache_entries: usize,
    pub upload_bytes: usize,
    pub instance_capacity: usize,
    pub instance_capacity_bytes: usize,
    pub known_buffer_count: usize,
    pub known_uniform_bytes: usize,
    pub depth_texture_logical_bytes: u64,
    pub draw_calls_min: usize,
    pub draw_calls_max: usize,
}
fn ms(start: Instant) -> f64 {
    start.elapsed().as_secs_f64() * 1000.0
}

struct TextLayout {
    title: String,
    buffer: Buffer,
}

pub struct Renderer {
    surface: wgpu::Surface<'static>,
    instance: wgpu::Instance,
    window: Arc<Window>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    size: PhysicalSize<u32>,
    pipeline: wgpu::RenderPipeline,
    uniform: wgpu::Buffer,
    bind_group: wgpu::BindGroup,
    instances: wgpu::Buffer,
    capacity: usize,
    scratch: Vec<Instance>,
    depth: Option<wgpu::TextureView>,
    fonts: FontSystem,
    swash: SwashCache,
    atlas: TextAtlas,
    text: TextRenderer,
    text_viewport: glyphon::Viewport,
    layouts: HashMap<WindowId, TextLayout>,
    visible: Vec<usize>,
    labels: Vec<Label>,
    depths: HashMap<usize, f32>,
    measure: bool,
    metrics: FrameMetrics,
    adapter_info: String,
    validation_flags: String,
    device_limits: String,
    timestamp_supported: bool,
    timestamp_requested: bool,
    frame_id: u64,
    gpu_timer: Option<gpu_timing::GpuTimer>,
}

impl std::fmt::Debug for Renderer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Renderer")
            .field("size", &self.size)
            .field("capacity", &self.capacity)
            .finish_non_exhaustive()
    }
}

const DEPTH_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Depth32Float;
fn depth_state(write: bool) -> wgpu::DepthStencilState {
    wgpu::DepthStencilState {
        format: DEPTH_FORMAT,
        depth_write_enabled: Some(write),
        depth_compare: Some(wgpu::CompareFunction::LessEqual),
        stencil: wgpu::StencilState::default(),
        bias: wgpu::DepthBiasState::default(),
    }
}

impl Renderer {
    /// # Errors
    /// Returns an error when a GPU surface, adapter or device cannot be created.
    #[allow(clippy::too_many_lines)]
    pub async fn new(
        window: Arc<Window>,
        on_gpu_error: Arc<dyn Fn(String) + Send + Sync>,
        timestamp_requested: bool,
    ) -> Result<Self, RenderError> {
        let size = window.inner_size();
        let mut descriptor = wgpu::InstanceDescriptor::new_without_display_handle();
        descriptor.backends = wgpu::Backends::METAL;
        let validation_flags = format!("{:?}", descriptor.flags);
        let instance = wgpu::Instance::new(descriptor);
        let surface = instance.create_surface(Arc::clone(&window))?;
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                compatible_surface: Some(&surface),
                ..Default::default()
            })
            .await?;
        let adapter_info = format!("{:?}", adapter.get_info());
        let timestamp_supported = adapter.features().contains(wgpu::Features::TIMESTAMP_QUERY);
        tracing::info!(adapter = %adapter_info, "selected GPU adapter");
        let required_features = if timestamp_requested && timestamp_supported {
            wgpu::Features::TIMESTAMP_QUERY
        } else {
            wgpu::Features::empty()
        };
        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                required_features,
                ..wgpu::DeviceDescriptor::default()
            })
            .await
            .map_err(|error| {
                if required_features.contains(wgpu::Features::TIMESTAMP_QUERY) {
                    RenderError::TimestampDevice(error)
                } else {
                    RenderError::Device(error)
                }
            })?;
        let gpu_timer = if required_features.contains(wgpu::Features::TIMESTAMP_QUERY) {
            gpu_timing::GpuTimer::new(&device, &queue)
        } else {
            None
        };
        let device_limits = format!("{:?}", device.limits());
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
        let uniform = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("viewport"),
            contents: bytemuck::cast_slice(&[1.0_f32, 1.0, 0.0, 0.0]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("viewport layout"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("viewport bind group"),
            layout: &layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: uniform.as_entire_binding(),
            }],
        });
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("windows"),
            source: wgpu::ShaderSource::Wgsl(include_str!("windows.wgsl").into()),
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("window pipeline layout"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let attributes = wgpu::vertex_attr_array![0 => Float32x4, 1 => Float32x4, 2 => Float32];
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("window pipeline"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                compilation_options: wgpu::PipelineCompilationOptions::default(),
                buffers: &[Some(wgpu::VertexBufferLayout {
                    array_stride: std::mem::size_of::<Instance>() as u64,
                    step_mode: wgpu::VertexStepMode::Instance,
                    attributes: &attributes,
                })],
            },
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: Some(depth_state(true)),
            multisample: wgpu::MultisampleState::default(),
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                compilation_options: wgpu::PipelineCompilationOptions::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format: config.format,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            multiview_mask: None,
            cache: None,
        });
        let capacity = 64;
        let instances = Self::instance_buffer(&device, capacity)?;
        let mut db = glyphon::fontdb::Database::new();
        db.load_font_data(include_bytes!("../assets/IBMPlexMono-Regular.ttf").to_vec());
        let fonts = FontSystem::new_with_locale_and_db("en-US".to_owned(), db);
        let cache = Cache::new(&device);
        let text_viewport = glyphon::Viewport::new(&device, &cache);
        let mut atlas = TextAtlas::new(&device, &queue, &cache, config.format);
        let text = TextRenderer::new(
            &mut atlas,
            &device,
            wgpu::MultisampleState::default(),
            Some(depth_state(false)),
        );
        let mut renderer = Self {
            surface,
            instance,
            window,
            device,
            queue,
            config,
            size,
            pipeline,
            uniform,
            bind_group,
            instances,
            capacity,
            scratch: Vec::new(),
            depth: None,
            fonts,
            swash: SwashCache::new(),
            atlas,
            text,
            text_viewport,
            layouts: HashMap::new(),
            visible: Vec::new(),
            labels: Vec::new(),
            depths: HashMap::new(),
            measure: false,
            metrics: FrameMetrics::default(),
            adapter_info,
            validation_flags,
            device_limits,
            timestamp_supported,
            timestamp_requested,
            frame_id: 0,
            gpu_timer,
        };
        renderer.configure();
        Ok(renderer)
    }

    fn instance_buffer(
        device: &wgpu::Device,
        capacity: usize,
    ) -> Result<wgpu::Buffer, RenderError> {
        let bytes = capacity
            .checked_mul(std::mem::size_of::<Instance>())
            .and_then(|v| u64::try_from(v).ok())
            .ok_or(RenderError::Capacity)?;
        Ok(device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("window instances"),
            size: bytes,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        }))
    }
    fn configure(&mut self) {
        if self.size.width > 0 && self.size.height > 0 {
            self.config.width = self.size.width;
            self.config.height = self.size.height;
            self.surface.configure(&self.device, &self.config);
            let texture = self.device.create_texture(&wgpu::TextureDescriptor {
                label: Some("window depth"),
                size: wgpu::Extent3d {
                    width: self.size.width,
                    height: self.size.height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: DEPTH_FORMAT,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                view_formats: &[],
            });
            self.depth = Some(texture.create_view(&wgpu::TextureViewDescriptor::default()));
        }
    }
    pub fn resize(&mut self, size: PhysicalSize<u32>) {
        self.size = size;
        self.configure();
    }

    pub const fn enable_metrics(&mut self) {
        self.measure = true;
    }
    #[must_use]
    pub const fn metrics(&self) -> FrameMetrics {
        self.metrics
    }
    #[must_use]
    pub fn validation_flags(&self) -> &str {
        &self.validation_flags
    }
    #[must_use]
    pub fn device_limits(&self) -> &str {
        &self.device_limits
    }
    #[must_use]
    pub const fn timestamp_supported(&self) -> bool {
        self.timestamp_supported
    }
    #[must_use]
    pub fn adapter_info(&self) -> &str {
        &self.adapter_info
    }
    #[must_use]
    pub const fn present_mode(&self) -> wgpu::PresentMode {
        self.config.present_mode
    }
    #[must_use]
    pub const fn physical_size(&self) -> PhysicalSize<u32> {
        self.size
    }

    /// Collects pending timestamp readbacks outside the event loop with a bounded timeout.
    pub fn finish_gpu_timing(&mut self) -> GpuReport {
        self.gpu_timer.take().map_or_else(
            || {
                let reason = if !self.timestamp_requested {
                    "not requested"
                } else if !self.timestamp_supported {
                    "adapter does not support TIMESTAMP_QUERY"
                } else {
                    "invalid timestamp period"
                };
                GpuReport::unavailable(self.timestamp_requested, self.timestamp_supported, reason)
            },
            |timer| timer.drain(&self.device, &self.queue, std::time::Duration::from_secs(2)),
        )
    }

    /// Prepares the first visible text layouts and glyphs before the initial redraw.
    ///
    /// # Errors
    /// Returns an error for invalid viewport geometry or text preparation failure.
    #[allow(clippy::cast_possible_truncation)]
    pub fn prewarm(
        &mut self,
        scene: &Scene,
        camera: Camera,
        selected: Option<WindowId>,
    ) -> Result<(), RenderError> {
        if self.size.width == 0 || self.size.height == 0 {
            return Ok(());
        }
        let viewport = Viewport::new(
            self.size.width,
            self.size.height,
            self.window.scale_factor(),
        )?;
        prepare::prepare(
            scene,
            camera,
            viewport,
            selected,
            &mut self.visible,
            &mut self.scratch,
            &mut self.labels,
        )?;
        self.text_viewport.update(
            &self.queue,
            Resolution {
                width: self.size.width,
                height: self.size.height,
            },
        );
        self.prepare_text(scene, (camera.zoom() * viewport.scale()) as f32)
    }

    /// # Errors
    /// Returns an error for invalid geometry or an unrecoverable GPU/text failure.
    #[allow(
        clippy::cast_precision_loss,
        clippy::cast_possible_truncation,
        clippy::too_many_lines
    )]
    pub fn render(
        &mut self,
        scene: &Scene,
        camera: Camera,
        selected: Option<WindowId>,
    ) -> Result<FrameOutcome, RenderError> {
        if self.size.width == 0 || self.size.height == 0 {
            return Ok(FrameOutcome::Occluded);
        }
        self.metrics.gpu_poll_ms = if let Some(timer) = &mut self.gpu_timer {
            let start = Instant::now();
            timer.poll(&self.device, &self.queue);
            Some(ms(start))
        } else {
            None
        };
        let mark = self.measure.then(Instant::now);
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
        self.frame_id = self.frame_id.checked_add(1).ok_or(RenderError::Capacity)?;
        self.metrics.frame_id = self.frame_id;
        if let Some(mark) = mark {
            self.metrics.acquire_ms = ms(mark);
        }
        let mark = self.measure.then(Instant::now);
        let viewport = Viewport::new(
            self.size.width,
            self.size.height,
            self.window.scale_factor(),
        )?;
        prepare::prepare(
            scene,
            camera,
            viewport,
            selected,
            &mut self.visible,
            &mut self.scratch,
            &mut self.labels,
        )?;
        if let Some(mark) = mark {
            self.metrics.geometry_ms = ms(mark);
        }
        let mark = self.measure.then(Instant::now);
        if self.scratch.len() > self.capacity {
            self.capacity = self
                .scratch
                .len()
                .checked_next_power_of_two()
                .ok_or(RenderError::Capacity)?;
            self.instances = Self::instance_buffer(&self.device, self.capacity)?;
        }
        self.queue
            .write_buffer(&self.instances, 0, bytemuck::cast_slice(&self.scratch));
        self.queue.write_buffer(
            &self.uniform,
            0,
            bytemuck::cast_slice(&[self.size.width as f32, self.size.height as f32, 0.0, 0.0]),
        );
        self.text_viewport.update(
            &self.queue,
            Resolution {
                width: self.size.width,
                height: self.size.height,
            },
        );
        if let Some(mark) = mark {
            self.metrics.upload_ms = ms(mark);
        }
        let mark = self.measure.then(Instant::now);
        self.prepare_text(scene, (camera.zoom() * viewport.scale()) as f32)?;
        if let Some(mark) = mark {
            self.metrics.text_ms = ms(mark);
        }
        let mark = self.measure.then(Instant::now);
        let view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let depth = self
            .depth
            .as_ref()
            .ok_or(RenderError::Frame("depth target unavailable"))?;
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("canvas encoder"),
            });
        let timing_slot = self
            .gpu_timer
            .as_mut()
            .and_then(|timer| timer.reserve(self.frame_id));
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("canvas"),
                timestamp_writes: timing_slot.and_then(|slot| {
                    self.gpu_timer
                        .as_ref()
                        .map(|timer| timer.timestamp_writes(slot))
                }),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: 0.025,
                            g: 0.030,
                            b: 0.032,
                            a: 1.0,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                    depth_slice: None,
                })],
                depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                    view: depth,
                    depth_ops: Some(wgpu::Operations {
                        load: wgpu::LoadOp::Clear(1.0),
                        store: wgpu::StoreOp::Discard,
                    }),
                    stencil_ops: None,
                }),
                ..Default::default()
            });
            pass.set_pipeline(&self.pipeline);
            pass.set_bind_group(0, &self.bind_group, &[]);
            pass.set_vertex_buffer(0, self.instances.slice(..));
            pass.draw(
                0..6,
                0..u32::try_from(self.scratch.len()).map_err(|_| RenderError::Capacity)?,
            );
            self.text
                .render(&self.atlas, &self.text_viewport, &mut pass)?;
        }
        let command = encoder.finish();
        if let Some(mark) = mark {
            self.metrics.encode_ms = ms(mark);
        }
        let mark = self.measure.then(Instant::now);
        self.queue.submit([command]);
        if let Some(slot) = timing_slot
            && let Some(timer) = &self.gpu_timer
        {
            timer.submitted(&self.queue, slot);
        }
        if let Some(mark) = mark {
            self.metrics.submit_ms = ms(mark);
        }
        let mark = self.measure.then(Instant::now);
        self.queue.present(frame);
        if let Some(mark) = mark {
            self.metrics.present_call_ms = ms(mark);
            self.metrics.visible = self.visible.len();
            self.metrics.primitives = self.scratch.len();
            self.metrics.labels = self.labels.len();
            self.metrics.retained_layouts = self.layouts.len();
            self.metrics.raster_cache_entries = self.swash.image_cache.len();
            self.metrics.upload_bytes = self.scratch.len() * std::mem::size_of::<Instance>() + 16;
            self.metrics.instance_capacity = self.capacity;
            self.metrics.instance_capacity_bytes = self.capacity * std::mem::size_of::<Instance>();
            self.metrics.known_buffer_count = 2;
            self.metrics.known_uniform_bytes = 16;
            self.metrics.depth_texture_logical_bytes =
                u64::from(self.size.width) * u64::from(self.size.height) * 4;
            self.metrics.draw_calls_min = 1;
            self.metrics.draw_calls_max = if self.labels.is_empty() { 1 } else { 2 };
        }
        drop(view);
        self.atlas.trim();
        if suboptimal {
            self.configure();
        }
        Ok(if suboptimal {
            FrameOutcome::Retry
        } else {
            FrameOutcome::Presented
        })
    }

    fn prepare_text(&mut self, scene: &Scene, scale: f32) -> Result<(), RenderError> {
        self.depths.clear();
        if self.measure {
            self.metrics.layout_hits = 0;
            self.metrics.layout_misses = 0;
        }
        if self.swash.image_cache.len() > 4096 {
            self.swash.image_cache.clear();
        }
        for label in &self.labels {
            let window = &scene.windows()[label.index];
            let id = window.id();
            let metadata = usize::try_from(id.0).map_err(|_| RenderError::Capacity)?;
            self.depths.insert(metadata, label.depth);
            let (entry, is_new) = match self.layouts.entry(id) {
                std::collections::hash_map::Entry::Occupied(entry) => (entry.into_mut(), false),
                std::collections::hash_map::Entry::Vacant(entry) => (
                    entry.insert(TextLayout {
                        title: String::new(),
                        buffer: Buffer::new(&mut self.fonts, Metrics::new(14.0, 20.0)),
                    }),
                    true,
                ),
            };
            let changed = is_new || entry.title != window.title;
            if self.measure {
                if changed {
                    self.metrics.layout_misses += 1;
                } else {
                    self.metrics.layout_hits += 1;
                }
            }
            if changed {
                entry.title.clone_from(&window.title);
                entry.buffer.set_text(
                    &entry.title,
                    &Attrs::new()
                        .family(Family::Name("IBM Plex Mono"))
                        .metadata(metadata),
                    Shaping::Advanced,
                    None,
                );
                entry.buffer.shape_until_scroll(&mut self.fonts, false);
            }
        }
        self.layouts
            .retain(|id, _| usize::try_from(id.0).is_ok_and(|id| self.depths.contains_key(&id)));
        let areas = self.labels.iter().filter_map(|label| {
            self.layouts
                .get(&scene.windows()[label.index].id())
                .map(|layout| TextArea {
                    buffer: &layout.buffer,
                    left: label.left,
                    top: label.top,
                    scale,
                    bounds: TextBounds {
                        left: label.bounds[0],
                        top: label.bounds[1],
                        right: label.bounds[2],
                        bottom: label.bounds[3],
                    },
                    default_color: Color::rgb(220, 227, 225),
                    custom_glyphs: &[],
                })
        });
        self.text.prepare_with_depth(
            &self.device,
            &self.queue,
            &mut self.fonts,
            &mut self.atlas,
            &self.text_viewport,
            areas,
            &mut self.swash,
            |metadata| self.depths.get(&metadata).copied().unwrap_or(1.0),
        )?;
        Ok(())
    }
}

/// Measures CPU-only visible filtering and geometry preparation; no GPU work is performed.
///
/// # Errors
/// Rejects unsupported viewport geometry.
pub fn benchmark_prepare(
    scene: &Scene,
    camera: Camera,
    viewport: Viewport,
    iterations: usize,
) -> Result<(f64, f64, f64, usize), RenderError> {
    use std::hint::black_box;
    let area = camera.bounds(viewport)?;
    let start = Instant::now();
    for _ in 0..iterations {
        black_box(black_box(scene).visible(black_box(area)).count());
    }
    let culling = ms(start);
    let mut visible = Vec::new();
    let mut instances = Vec::new();
    let mut labels = Vec::new();
    prepare::prepare(
        scene,
        camera,
        viewport,
        None,
        &mut visible,
        &mut instances,
        &mut labels,
    )?;
    let mut sort_time = std::time::Duration::ZERO;
    for _ in 0..iterations {
        let start = Instant::now();
        visible.sort_unstable_by_key(|index| (black_box(scene).windows()[*index].z, *index));
        sort_time += start.elapsed();
        black_box(&visible);
        visible.reverse();
    }
    let sort = sort_time.as_secs_f64() * 1000.0;
    let start = Instant::now();
    for _ in 0..iterations {
        prepare::prepare(
            black_box(scene),
            black_box(camera),
            black_box(viewport),
            None,
            &mut visible,
            &mut instances,
            &mut labels,
        )?;
        black_box(&instances);
    }
    Ok((culling, sort, ms(start), visible.len()))
}
