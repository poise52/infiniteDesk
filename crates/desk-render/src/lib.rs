mod prepare;

use desk_core::{Camera, Scene, Viewport, WindowId};
use glyphon::{
    Attrs, Buffer, Cache, Color, Family, FontSystem, Metrics, Resolution, Shaping, SwashCache,
    TextArea, TextAtlas, TextBounds, TextRenderer,
};
use prepare::{Instance, Label};
use std::{collections::HashMap, sync::Arc};
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
        self.prepare_text(scene, (camera.zoom() * viewport.scale()) as f32)?;
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
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("canvas"),
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
        self.queue.submit([encoder.finish()]);
        self.queue.present(frame);
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
        if self.swash.image_cache.len() > 4096 {
            self.swash.image_cache.clear();
        }
        for label in &self.labels {
            let window = &scene.windows()[label.index];
            let id = window.id();
            let metadata = usize::try_from(id.0).map_err(|_| RenderError::Capacity)?;
            self.depths.insert(metadata, label.depth);
            let entry = self.layouts.entry(id).or_insert_with(|| TextLayout {
                title: String::new(),
                buffer: Buffer::new(&mut self.fonts, Metrics::new(14.0, 20.0)),
            });
            if entry.title != window.title {
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
