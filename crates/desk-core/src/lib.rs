//! World geometry uses f64 units in ±1e12, zoom 0.01..=100 logical pixels per unit,
//! and display scales 0.25..=16 physical pixels per logical pixel. These are
//! application limits, not macOS limits. Rectangles are half-open. Calculations
//! near the world limit are quantized by f64 spacing (about 0.000122 units at
//! 1e12); results outside the supported range return an error. A zero-sized
//! physical viewport is invalid; callers must skip viewport operations when minimized.

use thiserror::Error;

pub const MAX_WORLD: f64 = 1_000_000_000_000.0;
pub const MIN_ZOOM: f64 = 0.01;
pub const MAX_ZOOM: f64 = 100.0;
const MAX_LOGICAL: f64 = 1_000_000_000.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum GeometryError {
    #[error("world coordinates or bounds are outside the supported range")]
    World,
    #[error("logical coordinates are outside the supported range")]
    Logical,
    #[error("viewport size or scale factor is invalid")]
    Viewport,
    #[error("zoom is outside the supported range")]
    Zoom,
    #[error("window ID is already present")]
    DuplicateId,
    #[error("window ID does not exist")]
    UnknownWindow,
    #[error("demo scene supports at most 10000 windows")]
    SceneSize,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WorldPoint {
    x: f64,
    y: f64,
}
impl WorldPoint {
    /// Creates a world point within ±1e12 units on each axis.
    ///
    /// # Errors
    /// Rejects non-finite or out-of-range coordinates.
    pub fn new(x: f64, y: f64) -> Result<Self, GeometryError> {
        if [x, y].iter().all(|v| v.is_finite() && v.abs() <= MAX_WORLD) {
            Ok(Self { x, y })
        } else {
            Err(GeometryError::World)
        }
    }
    #[must_use]
    pub const fn x(self) -> f64 {
        self.x
    }
    #[must_use]
    pub const fn y(self) -> f64 {
        self.y
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LogicalPoint {
    x: f64,
    y: f64,
}
impl LogicalPoint {
    /// Creates a point or displacement in logical pixels.
    ///
    /// # Errors
    /// Rejects non-finite values or magnitudes above 1e9.
    pub fn new(x: f64, y: f64) -> Result<Self, GeometryError> {
        if [x, y]
            .iter()
            .all(|v| v.is_finite() && v.abs() <= MAX_LOGICAL)
        {
            Ok(Self { x, y })
        } else {
            Err(GeometryError::Logical)
        }
    }
    #[must_use]
    pub const fn x(self) -> f64 {
        self.x
    }
    #[must_use]
    pub const fn y(self) -> f64 {
        self.y
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PhysicalPoint {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Viewport {
    width: f64,
    height: f64,
    scale: f64,
}
impl Viewport {
    /// Builds a viewport from physical pixels and the physical-pixels-per-logical-pixel scale.
    ///
    /// # Errors
    /// Rejects zero dimensions, scales outside 0.25..=16, and logical sizes over 1e9.
    pub fn new(width: u32, height: u32, scale: f64) -> Result<Self, GeometryError> {
        if width == 0 || height == 0 || !scale.is_finite() || !(0.25..=16.0).contains(&scale) {
            return Err(GeometryError::Viewport);
        }
        let width = f64::from(width) / scale;
        let height = f64::from(height) / scale;
        if width > MAX_LOGICAL || height > MAX_LOGICAL {
            return Err(GeometryError::Viewport);
        }
        Ok(Self {
            width,
            height,
            scale,
        })
    }
    #[must_use]
    pub const fn width(self) -> f64 {
        self.width
    }
    #[must_use]
    pub const fn height(self) -> f64 {
        self.height
    }
    #[must_use]
    pub const fn scale(self) -> f64 {
        self.scale
    }
    /// Converts finite physical pixel coordinates to logical pixels.
    ///
    /// # Errors
    /// Rejects non-finite or out-of-range results.
    pub fn to_logical(self, p: PhysicalPoint) -> Result<LogicalPoint, GeometryError> {
        LogicalPoint::new(p.x / self.scale, p.y / self.scale)
    }
    #[must_use]
    pub fn to_physical(self, p: LogicalPoint) -> PhysicalPoint {
        PhysicalPoint {
            x: p.x * self.scale,
            y: p.y * self.scale,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WorldRect {
    origin: WorldPoint,
    width: f64,
    height: f64,
}
impl WorldRect {
    /// Bounds are half-open: left/top inclusive and right/bottom exclusive.
    ///
    /// # Errors
    /// Rejects non-positive sizes and bounds outside the world range.
    pub fn new(origin: WorldPoint, width: f64, height: f64) -> Result<Self, GeometryError> {
        if !width.is_finite() || !height.is_finite() || width <= 0.0 || height <= 0.0 {
            return Err(GeometryError::World);
        }
        let right = origin.x + width;
        let bottom = origin.y + height;
        if right > MAX_WORLD || bottom > MAX_WORLD || right <= origin.x || bottom <= origin.y {
            return Err(GeometryError::World);
        }
        Ok(Self {
            origin,
            width,
            height,
        })
    }
    #[must_use]
    pub const fn origin(self) -> WorldPoint {
        self.origin
    }
    #[must_use]
    pub const fn width(self) -> f64 {
        self.width
    }
    #[must_use]
    pub const fn height(self) -> f64 {
        self.height
    }
    #[must_use]
    pub fn contains(self, p: WorldPoint) -> bool {
        p.x >= self.origin.x
            && p.x < self.origin.x + self.width
            && p.y >= self.origin.y
            && p.y < self.origin.y + self.height
    }
    #[must_use]
    pub fn intersects(self, other: Self) -> bool {
        self.origin.x < other.origin.x + other.width
            && other.origin.x < self.origin.x + self.width
            && self.origin.y < other.origin.y + other.height
            && other.origin.y < self.origin.y + self.height
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Camera {
    center: WorldPoint,
    zoom: f64,
}
impl Camera {
    /// The center is in world units; zoom is logical pixels per world unit.
    ///
    /// # Errors
    /// Rejects non-finite zoom or values outside 0.01..=100.
    pub fn new(center: WorldPoint, zoom: f64) -> Result<Self, GeometryError> {
        if !zoom.is_finite() || !(MIN_ZOOM..=MAX_ZOOM).contains(&zoom) {
            return Err(GeometryError::Zoom);
        }
        Ok(Self { center, zoom })
    }
    #[must_use]
    pub const fn center(self) -> WorldPoint {
        self.center
    }
    #[must_use]
    pub const fn zoom(self) -> f64 {
        self.zoom
    }
    /// # Errors
    /// Rejects a transformed coordinate outside the logical range.
    pub fn world_to_screen(
        self,
        p: WorldPoint,
        v: Viewport,
    ) -> Result<LogicalPoint, GeometryError> {
        LogicalPoint::new(
            (p.x - self.center.x).mul_add(self.zoom, v.width / 2.0),
            (p.y - self.center.y).mul_add(self.zoom, v.height / 2.0),
        )
    }
    /// # Errors
    /// Rejects a transformed coordinate outside the world range.
    pub fn screen_to_world(
        self,
        p: LogicalPoint,
        v: Viewport,
    ) -> Result<WorldPoint, GeometryError> {
        WorldPoint::new(
            self.center.x + (p.x - v.width / 2.0) / self.zoom,
            self.center.y + (p.y - v.height / 2.0) / self.zoom,
        )
    }
    /// Moves the camera by a logical-pixel displacement; positive values move the camera right/down.
    ///
    /// # Errors
    /// Leaves the camera unchanged if the resulting center is outside the world range.
    pub fn pan(&mut self, delta: LogicalPoint) -> Result<(), GeometryError> {
        self.center = WorldPoint::new(
            self.center.x + delta.x / self.zoom,
            self.center.y + delta.y / self.zoom,
        )?;
        Ok(())
    }
    /// Changes zoom while keeping the world point under the logical cursor fixed, within f64 precision.
    ///
    /// # Errors
    /// Leaves the camera unchanged for invalid zoom or out-of-range coordinates.
    pub fn zoom_at(
        &mut self,
        zoom: f64,
        cursor: LogicalPoint,
        viewport: Viewport,
    ) -> Result<(), GeometryError> {
        let mut next = Self::new(self.center, zoom)?;
        let anchor = self.screen_to_world(cursor, viewport)?;
        next.center = WorldPoint::new(
            anchor.x - (cursor.x - viewport.width / 2.0) / zoom,
            anchor.y - (cursor.y - viewport.height / 2.0) / zoom,
        )?;
        *self = next;
        Ok(())
    }
    /// # Errors
    /// Rejects a viewport whose world bounds exceed the supported range.
    pub fn bounds(self, v: Viewport) -> Result<WorldRect, GeometryError> {
        let origin = WorldPoint::new(
            self.center.x - v.width / (2.0 * self.zoom),
            self.center.y - v.height / (2.0 * self.zoom),
        )?;
        WorldRect::new(origin, v.width / self.zoom, v.height / self.zoom)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct WindowId(pub u64);

#[derive(Debug, Clone, PartialEq)]
pub struct Window {
    id: WindowId,
    pub title: String,
    bounds: WorldRect,
    pub color: [u8; 4],
    pub z: i64,
    pub visible: bool,
}
impl Window {
    #[must_use]
    pub const fn new(
        id: WindowId,
        title: String,
        bounds: WorldRect,
        color: [u8; 4],
        z: i64,
    ) -> Self {
        Self {
            id,
            title,
            bounds,
            color,
            z,
            visible: true,
        }
    }
    #[must_use]
    pub const fn id(&self) -> WindowId {
        self.id
    }
    #[must_use]
    pub const fn bounds(&self) -> WorldRect {
        self.bounds
    }
}

#[derive(Debug, Clone, Default)]
pub struct Scene {
    windows: Vec<Window>,
}
impl Scene {
    #[must_use]
    pub fn windows(&self) -> &[Window] {
        &self.windows
    }
    /// # Errors
    /// Rejects an ID already owned by this scene.
    pub fn add(&mut self, window: Window) -> Result<(), GeometryError> {
        if self.windows.iter().any(|w| w.id == window.id) {
            return Err(GeometryError::DuplicateId);
        }
        self.windows.push(window);
        Ok(())
    }
    #[must_use]
    pub fn remove(&mut self, id: WindowId) -> Option<Window> {
        self.windows
            .iter()
            .position(|w| w.id == id)
            .map(|i| self.windows.remove(i))
    }
    #[must_use]
    pub fn get(&self, id: WindowId) -> Option<&Window> {
        self.windows.iter().find(|w| w.id == id)
    }
    /// # Errors
    /// Rejects an unknown window ID.
    pub fn set_visible(&mut self, id: WindowId, visible: bool) -> Result<(), GeometryError> {
        let window = self
            .windows
            .iter_mut()
            .find(|w| w.id == id)
            .ok_or(GeometryError::UnknownWindow)?;
        window.visible = visible;
        Ok(())
    }
    /// # Errors
    /// Rejects an unknown window ID.
    pub fn set_z(&mut self, id: WindowId, z: i64) -> Result<(), GeometryError> {
        let window = self
            .windows
            .iter_mut()
            .find(|w| w.id == id)
            .ok_or(GeometryError::UnknownWindow)?;
        window.z = z;
        Ok(())
    }
    /// Returns visible windows intersecting the half-open area, in insertion order.
    pub fn visible(&self, area: WorldRect) -> impl Iterator<Item = &Window> {
        self.windows
            .iter()
            .filter(move |w| w.visible && w.bounds.intersects(area))
    }
    /// Higher z wins; ties are resolved by later insertion.
    #[must_use]
    pub fn hit_test(&self, p: WorldPoint) -> Option<&Window> {
        self.windows
            .iter()
            .filter(|w| w.visible && w.bounds.contains(p))
            .max_by_key(|w| w.z)
    }
    /// Applies a world-space drag delta atomically.
    ///
    /// # Errors
    /// Rejects an unknown ID or a move that would leave supported bounds.
    pub fn drag(&mut self, id: WindowId, delta_x: f64, delta_y: f64) -> Result<(), GeometryError> {
        let w = self
            .windows
            .iter_mut()
            .find(|w| w.id == id)
            .ok_or(GeometryError::UnknownWindow)?;
        let origin = WorldPoint::new(w.bounds.origin.x + delta_x, w.bounds.origin.y + delta_y)?;
        w.bounds = WorldRect::new(origin, w.bounds.width, w.bounds.height)?;
        Ok(())
    }
    /// Generates reproducible demo windows for the same seed and count.
    ///
    /// # Errors
    /// Rejects counts above 10000.
    pub fn demo(count: usize, seed: u64) -> Result<Self, GeometryError> {
        if count > 10_000 {
            return Err(GeometryError::SceneSize);
        }
        let mut rng = seed;
        let mut windows = Vec::with_capacity(count);
        for i in 0..count {
            let id = u64::try_from(i).map_err(|_| GeometryError::SceneSize)?;
            let x = f64::from(
                u32::try_from(splitmix(&mut rng) % 100_000)
                    .map_err(|_| GeometryError::SceneSize)?,
            ) - 50_000.0;
            let y = f64::from(
                u32::try_from(splitmix(&mut rng) % 100_000)
                    .map_err(|_| GeometryError::SceneSize)?,
            ) - 50_000.0;
            let width = f64::from(
                u32::try_from(splitmix(&mut rng) % 300 + 180)
                    .map_err(|_| GeometryError::SceneSize)?,
            );
            let height = f64::from(
                u32::try_from(splitmix(&mut rng) % 240 + 120)
                    .map_err(|_| GeometryError::SceneSize)?,
            );
            let bytes = splitmix(&mut rng).to_le_bytes();
            let bounds = WorldRect::new(WorldPoint::new(x, y)?, width, height)?;
            windows.push(Window::new(
                WindowId(id),
                format!("Window {id}"),
                bounds,
                [bytes[0], bytes[1], bytes[2], 255],
                i64::try_from(i).map_err(|_| GeometryError::SceneSize)?,
            ));
        }
        Ok(Self { windows })
    }
}

const fn splitmix(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9e37_79b9_7f4a_7c15);
    let mut x = *state;
    x = (x ^ (x >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    x = (x ^ (x >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    x ^ (x >> 31)
}

#[cfg(test)]
mod tests;
