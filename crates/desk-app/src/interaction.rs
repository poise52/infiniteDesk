use desk_core::{
    Camera, GeometryError, LogicalPoint, MAX_WORLD, MAX_ZOOM, MIN_ZOOM, PhysicalPoint, Scene,
    Viewport, WindowId, WorldPoint,
};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy)]
enum Gesture {
    Pan {
        last: LogicalPoint,
        last_at: Instant,
        velocity: [f64; 2],
    },
    Drag {
        id: WindowId,
        last: WorldPoint,
    },
}

#[derive(Debug)]
pub struct Board {
    pub scene: Scene,
    pub camera: Camera,
    pub selected: Option<WindowId>,
    viewport: Option<Viewport>,
    cursor: Option<LogicalPoint>,
    gesture: Option<Gesture>,
    velocity: [f64; 2],
    inertia_at: Option<Instant>,
}

impl Board {
    pub const fn new(scene: Scene, camera: Camera, selected: Option<WindowId>) -> Self {
        Self {
            scene,
            camera,
            selected,
            viewport: None,
            cursor: None,
            gesture: None,
            velocity: [0.0, 0.0],
            inertia_at: None,
        }
    }
    pub fn resize(&mut self, width: u32, height: u32, scale: f64) {
        self.cancel();
        self.cursor = None;
        self.viewport = Viewport::new(width, height, scale).ok();
        if let Some(viewport) = self.viewport
            && self.camera.bounds(viewport).is_err()
        {
            let zoom = self
                .camera
                .zoom()
                .max(viewport.width().max(viewport.height()) / (2.0 * (MAX_WORLD - 2048.0)))
                .min(MAX_ZOOM);
            let half_x = viewport.width() / (2.0 * zoom);
            let half_y = viewport.height() / (2.0 * zoom);
            let (min_x, max_x) = (-MAX_WORLD + half_x + 1.0, MAX_WORLD - half_x - 1.0);
            let (min_y, max_y) = (-MAX_WORLD + half_y + 1.0, MAX_WORLD - half_y - 1.0);
            if min_x > max_x || min_y > max_y {
                self.viewport = None;
                return;
            }
            let x = self.camera.center().x().clamp(min_x, max_x);
            let y = self.camera.center().y().clamp(min_y, max_y);
            if let Ok(camera) = WorldPoint::new(x, y).and_then(|center| Camera::new(center, zoom)) {
                if camera.bounds(viewport).is_ok() {
                    self.camera = camera;
                } else {
                    self.viewport = None;
                }
            } else {
                self.viewport = None;
            }
        }
    }
    pub const fn has_viewport(&self) -> bool {
        self.viewport.is_some()
    }
    pub const fn cancel(&mut self) {
        self.gesture = None;
        self.velocity = [0.0, 0.0];
        self.inertia_at = None;
    }
    pub const fn cursor_left(&mut self) {
        self.cancel();
        self.cursor = None;
    }
    fn commit_camera(&mut self, camera: Camera) -> bool {
        if self
            .viewport
            .is_some_and(|viewport| camera.bounds(viewport).is_ok())
        {
            self.camera = camera;
            true
        } else {
            false
        }
    }
    fn move_camera(&mut self, x: f64, y: f64) -> bool {
        let Ok(delta) = LogicalPoint::new(x, y) else {
            return false;
        };
        let mut camera = self.camera;
        if camera.pan(delta).is_err() {
            return false;
        }
        self.commit_camera(camera)
    }
    pub fn cursor_moved(&mut self, point: PhysicalPoint, now: Instant) -> bool {
        let Some(viewport) = self.viewport else {
            return false;
        };
        let Ok(cursor) = viewport.to_logical(point) else {
            self.cursor_left();
            return false;
        };
        self.cursor = Some(cursor);
        match self.gesture {
            Some(Gesture::Pan { last, last_at, .. }) => {
                let dx = last.x() - cursor.x();
                let dy = last.y() - cursor.y();
                let moved = self.move_camera(dx, dy);
                let dt = now.saturating_duration_since(last_at).as_secs_f64();
                let velocity = if moved && (0.001..=0.1).contains(&dt) {
                    [dx / dt, dy / dt]
                } else {
                    [0.0, 0.0]
                };
                self.gesture = Some(Gesture::Pan {
                    last: cursor,
                    last_at: now,
                    velocity,
                });
                moved
            }
            Some(Gesture::Drag { id, last }) => {
                let Ok(next) = self.camera.screen_to_world(cursor, viewport) else {
                    return false;
                };
                let moved = self
                    .scene
                    .drag(id, next.x() - last.x(), next.y() - last.y())
                    .is_ok();
                if moved {
                    self.gesture = Some(Gesture::Drag { id, last: next });
                }
                moved
            }
            None => false,
        }
    }
    pub const fn start_pan(&mut self, now: Instant) {
        self.cancel();
        if let Some(last) = self.cursor {
            self.gesture = Some(Gesture::Pan {
                last,
                last_at: now,
                velocity: [0.0, 0.0],
            });
        }
    }
    pub fn start_select(&mut self) -> bool {
        self.cancel();
        let (Some(cursor), Some(viewport)) = (self.cursor, self.viewport) else {
            return false;
        };
        let Ok(world) = self.camera.screen_to_world(cursor, viewport) else {
            return false;
        };
        let id = self.scene.hit_test(world).map(desk_core::Window::id);
        let changed = self.selected != id;
        self.selected = id;
        if let Some(id) = id {
            if self.scene.raise(id).is_err() {
                return changed;
            }
            self.gesture = Some(Gesture::Drag { id, last: world });
            return true;
        }
        changed
    }
    pub fn release(&mut self, now: Instant) -> bool {
        if let Some(Gesture::Pan {
            last_at, velocity, ..
        }) = self.gesture.take()
            && now.saturating_duration_since(last_at) <= Duration::from_millis(100)
            && velocity[0].hypot(velocity[1]) > 30.0
        {
            self.velocity = velocity;
            self.inertia_at = Some(now);
            return true;
        }
        false
    }
    pub fn wheel_pan(&mut self, dx: f64, dy: f64) -> bool {
        self.cancel();
        self.move_camera(-dx, -dy)
    }
    pub fn zoom(&mut self, factor: f64) -> bool {
        self.cancel();
        let (Some(cursor), Some(viewport)) = (self.cursor, self.viewport) else {
            return false;
        };
        if !factor.is_finite() || factor <= 0.0 {
            return false;
        }
        let zoom = (self.camera.zoom() * factor).clamp(MIN_ZOOM, MAX_ZOOM);
        let mut camera = self.camera;
        if camera.zoom_at(zoom, cursor, viewport).is_err() {
            return false;
        }
        self.commit_camera(camera)
    }
    pub const fn inertia_active(&self) -> bool {
        self.inertia_at.is_some()
    }
    pub fn tick(&mut self, now: Instant) -> bool {
        let Some(last) = self.inertia_at else {
            return false;
        };
        let dt = now.saturating_duration_since(last).as_secs_f64().min(0.05);
        if dt == 0.0 {
            return false;
        }
        let decay = (-7.0 * dt).exp();
        let travel = (1.0 - decay) / 7.0;
        let moved = self.move_camera(self.velocity[0] * travel, self.velocity[1] * travel);
        self.velocity[0] *= decay;
        self.velocity[1] *= decay;
        if !moved || self.velocity[0].hypot(self.velocity[1]) < 2.0 {
            self.cancel();
        } else {
            self.inertia_at = Some(now);
        }
        moved
    }
    pub fn reset(&mut self) -> bool {
        self.cancel();
        let Ok(center) = WorldPoint::new(0.0, 0.0) else {
            return false;
        };
        let Ok(camera) = Camera::new(center, 1.0) else {
            return false;
        };
        self.commit_camera(camera)
    }
    pub fn focus_selected(&mut self) -> bool {
        self.cancel();
        let Some(window) = self.selected.and_then(|id| self.scene.get(id)) else {
            return false;
        };
        let bounds = window.bounds();
        let Ok(center) = WorldPoint::new(
            bounds.origin().x() + bounds.width() / 2.0,
            bounds.origin().y() + bounds.height() / 2.0,
        ) else {
            return false;
        };
        let Ok(camera) = Camera::new(center, self.camera.zoom()) else {
            return false;
        };
        self.commit_camera(camera)
    }
    pub fn fit_all(&mut self) -> bool {
        self.cancel();
        let Some(viewport) = self.viewport else {
            return false;
        };
        let mut windows = self.scene.windows().iter().filter(|window| window.visible);
        let Some(first) = windows.next() else {
            return false;
        };
        let b = first.bounds();
        let (mut left, mut top, mut right, mut bottom) = (
            b.origin().x(),
            b.origin().y(),
            b.origin().x() + b.width(),
            b.origin().y() + b.height(),
        );
        for w in windows {
            let b = w.bounds();
            left = left.min(b.origin().x());
            top = top.min(b.origin().y());
            right = right.max(b.origin().x() + b.width());
            bottom = bottom.max(b.origin().y() + b.height());
        }
        let zoom = (viewport.width() * 0.90 / (right - left))
            .min(viewport.height() * 0.90 / (bottom - top))
            .min(MAX_ZOOM);
        if zoom < MIN_ZOOM {
            return false;
        }
        let Ok(center) = WorldPoint::new(left + (right - left) / 2.0, top + (bottom - top) / 2.0)
        else {
            return false;
        };
        let Ok(camera) = Camera::new(center, zoom) else {
            return false;
        };
        self.commit_camera(camera)
    }
    pub fn cycle(&mut self, backwards: bool) -> bool {
        self.cancel();
        let ids: Vec<_> = self
            .scene
            .windows()
            .iter()
            .filter(|w| w.visible)
            .map(desk_core::Window::id)
            .collect();
        if ids.is_empty() {
            self.selected = None;
            return false;
        }
        let next = self
            .selected
            .and_then(|id| ids.iter().position(|candidate| *candidate == id))
            .map_or(if backwards { ids.len() - 1 } else { 0 }, |index| {
                if backwards {
                    (index + ids.len() - 1) % ids.len()
                } else {
                    (index + 1) % ids.len()
                }
            });
        self.selected = Some(ids[next]);
        self.focus_selected();
        true
    }
}

pub fn clustered_demo(count: usize, seed: u64) -> Result<Scene, GeometryError> {
    let mut scene = Scene::demo(count, seed)?;
    for index in 0_u64..12.min(u64::try_from(count).map_err(|_| GeometryError::SceneSize)?) {
        let id = WindowId(index);
        let origin = scene
            .get(id)
            .ok_or(GeometryError::UnknownWindow)?
            .bounds()
            .origin();
        let x = if index == 2 {
            -190.0
        } else {
            f64::from(u32::try_from(index % 4).map_err(|_| GeometryError::SceneSize)?)
                .mul_add(245.0, -470.0)
        };
        let y = if index == 2 {
            -285.0
        } else {
            f64::from(u32::try_from(index / 4).map_err(|_| GeometryError::SceneSize)?)
                .mul_add(190.0, -300.0)
        };
        scene.drag(id, x - origin.x(), y - origin.y())?;
    }
    Ok(scene)
}

#[cfg(test)]
mod tests {
    use super::*;
    use desk_core::{Window, WorldRect};

    fn test_board() -> Result<Board, GeometryError> {
        let mut scene = Scene::default();
        let bounds = WorldRect::new(WorldPoint::new(-50.0, -50.0)?, 100.0, 100.0)?;
        scene.add(Window::new(
            WindowId(1),
            "one".into(),
            bounds,
            [0, 0, 0, 255],
            0,
        ))?;
        scene.add(Window::new(
            WindowId(2),
            "two".into(),
            bounds,
            [0, 0, 0, 255],
            1,
        ))?;
        let mut board = Board::new(scene, Camera::new(WorldPoint::new(0.0, 0.0)?, 1.0)?, None);
        board.resize(800, 600, 1.0);
        Ok(board)
    }
    fn pos(x: f64, y: f64) -> PhysicalPoint {
        PhysicalPoint { x, y }
    }

    #[test]
    fn replay_select_drag_and_conflicting_zoom() -> Result<(), GeometryError> {
        let mut b = test_board()?;
        let now = Instant::now();
        b.cursor_moved(pos(400.0, 300.0), now);
        assert!(b.start_select());
        assert_eq!(b.selected, Some(WindowId(2)));
        assert!(b.cursor_moved(pos(420.0, 310.0), now + Duration::from_millis(16)));
        assert_eq!(
            b.scene
                .get(WindowId(2))
                .ok_or(GeometryError::UnknownWindow)?
                .bounds()
                .origin(),
            WorldPoint::new(-30.0, -40.0)?
        );
        let viewport = Viewport::new(800, 600, 1.0)?;
        let cursor = LogicalPoint::new(420.0, 310.0)?;
        let before = b.camera.screen_to_world(cursor, viewport)?;
        assert!(b.zoom(2.0));
        let after = b.camera.screen_to_world(cursor, viewport)?;
        assert!((before.x() - after.x()).abs() < 1e-9 && (before.y() - after.y()).abs() < 1e-9);
        let origin = b
            .scene
            .get(WindowId(2))
            .ok_or(GeometryError::UnknownWindow)?
            .bounds()
            .origin();
        assert!(!b.cursor_moved(pos(430.0, 320.0), now + Duration::from_millis(32)));
        assert_eq!(
            b.scene
                .get(WindowId(2))
                .ok_or(GeometryError::UnknownWindow)?
                .bounds()
                .origin(),
            origin
        );
        Ok(())
    }
    #[test]
    fn pan_inertia_and_focus_loss_cancel_gestures() -> Result<(), GeometryError> {
        let mut b = test_board()?;
        let now = Instant::now();
        b.cursor_moved(pos(400.0, 300.0), now);
        b.start_pan(now);
        assert!(b.cursor_moved(pos(440.0, 300.0), now + Duration::from_millis(20)));
        assert_eq!(b.camera.center(), WorldPoint::new(-40.0, 0.0)?);
        assert!(b.release(now + Duration::from_millis(21)));
        assert!(b.tick(now + Duration::from_millis(37)));
        assert!(b.camera.center().x() < -40.0);
        b.cursor_left();
        assert!(!b.inertia_active());
        assert!(!b.tick(now + Duration::from_millis(60)));
        assert!(!b.start_select());
        Ok(())
    }
    #[test]
    fn fit_all_contains_all_demo_bounds_and_resize_is_safe_at_edge() -> Result<(), GeometryError> {
        let scene = clustered_demo(10_000, 42)?;
        let camera = Camera::new(WorldPoint::new(0.0, 0.0)?, 1.0)?;
        let mut b = Board::new(scene, camera, None);
        b.resize(800, 632, 2.0);
        assert!(b.fit_all());
        let area = b.camera.bounds(Viewport::new(800, 632, 2.0)?)?;
        for w in b.scene.windows() {
            let bounds = w.bounds();
            assert!(bounds.origin().x() >= area.origin().x());
            assert!(bounds.origin().y() >= area.origin().y());
            assert!(bounds.origin().x() + bounds.width() <= area.origin().x() + area.width());
            assert!(bounds.origin().y() + bounds.height() <= area.origin().y() + area.height());
        }
        b.camera = Camera::new(WorldPoint::new(MAX_WORLD - 2.0, 0.0)?, 1.0)?;
        b.resize(1600, 900, 1.0);
        assert!(b.camera.bounds(Viewport::new(1600, 900, 1.0)?).is_ok());
        b.cursor_moved(pos(500.0, 400.0), Instant::now());
        let before = b.camera;
        assert!(!b.wheel_pan(-1e9, 0.0));
        assert_eq!(b.camera, before);
        b.resize(0, 0, 1.0);
        assert!(!b.fit_all());
        assert!(!b.inertia_active());
        Ok(())
    }
    #[test]
    fn extreme_resize_never_panics_and_keeps_bounds_valid() -> Result<(), GeometryError> {
        let camera = Camera::new(WorldPoint::new(0.0, 0.0)?, MIN_ZOOM)?;
        let mut board = Board::new(Scene::default(), camera, None);
        board.resize(292_563_231, 1, 1.0);
        assert!(board.has_viewport());
        assert!(
            board
                .camera
                .bounds(Viewport::new(292_563_231, 1, 1.0)?)
                .is_ok()
        );
        Ok(())
    }
    #[test]
    fn initial_focus_centers_the_requested_window() -> Result<(), GeometryError> {
        let scene = clustered_demo(100, 42)?;
        let id = WindowId(99);
        let bounds = scene.get(id).ok_or(GeometryError::UnknownWindow)?.bounds();
        let expected = WorldPoint::new(
            bounds.origin().x() + bounds.width() / 2.0,
            bounds.origin().y() + bounds.height() / 2.0,
        )?;
        let mut board = Board::new(
            scene,
            Camera::new(WorldPoint::new(0.0, 0.0)?, 1.0)?,
            Some(id),
        );
        board.resize(800, 600, 2.0);
        assert!(board.focus_selected());
        assert_eq!(board.camera.center(), expected);
        assert_eq!(board.selected, Some(id));
        Ok(())
    }
    #[test]
    fn empty_scene_and_invalid_zoom_leave_state_intact() -> Result<(), GeometryError> {
        let mut b = Board::new(
            Scene::default(),
            Camera::new(WorldPoint::new(0.0, 0.0)?, 1.0)?,
            None,
        );
        b.resize(800, 600, 1.0);
        let before = b.camera;
        assert!(!b.fit_all());
        assert!(!b.cycle(false));
        b.cursor_moved(pos(100.0, 100.0), Instant::now());
        assert!(!b.zoom(f64::NAN));
        assert_eq!(b.camera, before);
        Ok(())
    }
}

#[cfg(test)]
mod timing_tests {
    use super::*;
    #[test]
    fn inertia_distance_is_stable_across_frame_rates() -> Result<(), GeometryError> {
        let now = Instant::now();
        let camera = Camera::new(WorldPoint::new(0.0, 0.0)?, 1.0)?;
        let mut a = Board::new(Scene::default(), camera, None);
        let mut b = Board::new(Scene::default(), camera, None);
        a.resize(800, 600, 1.0);
        b.resize(800, 600, 1.0);
        a.velocity = [1000.0, -300.0];
        b.velocity = a.velocity;
        a.inertia_at = Some(now);
        b.inertia_at = Some(now);
        for frame in 1..=60 {
            a.tick(now + Duration::from_secs_f64(f64::from(frame) / 120.0));
        }
        for frame in 1..=30 {
            b.tick(now + Duration::from_secs_f64(f64::from(frame) / 60.0));
        }
        assert!((a.camera.center().x() - b.camera.center().x()).abs() < 1e-6);
        assert!((a.camera.center().y() - b.camera.center().y()).abs() < 1e-6);
        Ok(())
    }
}
