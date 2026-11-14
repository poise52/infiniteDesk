use std::{ffi::c_void, marker::PhantomData, ptr::NonNull, rc::Rc, sync::Arc};

use anyhow::{Context, Result, bail};
use desk_core::{Scene, Viewport, Window as Card, WindowId, WorldPoint, WorldRect};
use winit::{
    raw_window_handle::{HasWindowHandle, RawWindowHandle},
    window::Window,
};

use crate::interaction::Board;

pub const INITIAL_CARDS: u64 = 2;
const MAX_CARDS: usize = 3;

unsafe extern "C" {
    fn desk_browser_create_card(parent: *mut c_void, id: u64, start_web: u8) -> *mut c_void;
    fn desk_browser_set_frame(
        handle: *mut c_void,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        zoom: f64,
        viewport_width: f64,
        viewport_height: f64,
    );
    fn desk_browser_set_occluders(
        handle: *mut c_void,
        x1: f64,
        y1: f64,
        w1: f64,
        h1: f64,
        x2: f64,
        y2: f64,
        w2: f64,
        h2: f64,
    );
    fn desk_browser_set_selected(handle: *mut c_void, selected: u8);
    fn desk_browser_destroy(handle: *mut c_void);
}

pub fn is_bundle_demo() -> bool {
    std::env::current_exe()
        .ok()
        .and_then(|path| {
            path.parent()?
                .parent()
                .map(|contents| contents.join("Resources/build-marker.txt"))
        })
        .and_then(|path| std::fs::read_to_string(path).ok())
        .is_some_and(|marker| marker == "InfiniteDesk local demo bundle\n")
}

pub fn scene() -> Result<Scene> {
    let mut scene = Scene::default();
    scene.add(card(0)?)?;
    scene.add(card(1)?)?;
    Ok(scene)
}

fn card(id: u64) -> Result<Card> {
    let x = match id {
        0 => -580.0,
        1 => 20.0,
        _ => 620.0,
    };
    let title = format!("Card {} · N: up to 3 cards", id + 1);
    Ok(Card::new(
        WindowId(id),
        title,
        WorldRect::new(WorldPoint::new(x, -260.0)?, 560.0, 520.0)?,
        [90, 130, 120, 255],
        i64::try_from(id)?,
    ))
}

#[derive(PartialEq, Eq)]
pub enum Mode {
    Board,
    Browser,
}

pub struct Browser {
    id: WindowId,
    handle: NonNull<c_void>,
    window: Arc<Window>,
    _main_thread: PhantomData<Rc<()>>,
}

impl Browser {
    pub fn new(window: Arc<Window>, id: WindowId) -> Result<Self> {
        let handle = window
            .window_handle()
            .context("failed to get native window")?;
        let RawWindowHandle::AppKit(handle) = handle.as_raw() else {
            bail!("browser requires an AppKit window");
        };
        // SAFETY: winit supplies a live NSView on the main thread. The Arc keeps its
        // window alive until the browser is detached in Drop.
        let browser =
            unsafe { desk_browser_create_card(handle.ns_view.as_ptr(), id.0, u8::from(id.0 == 0)) };
        let handle = NonNull::new(browser).context("failed to create native browser")?;
        Ok(Self {
            id,
            handle,
            window,
            _main_thread: PhantomData,
        })
    }

    pub fn set_selected(&self, selected: Option<WindowId>) {
        // SAFETY: the owned handle and parent window remain alive on the main thread.
        unsafe {
            desk_browser_set_selected(self.handle.as_ptr(), u8::from(selected == Some(self.id)))
        };
    }

    fn hide(&mut self) {
        // SAFETY: the handle remains valid and is used on the creating main thread.
        unsafe { desk_browser_set_frame(self.handle.as_ptr(), 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0) };
    }

    pub fn update(&mut self, board: &Board) {
        let Some(card) = board.scene.get(self.id) else {
            self.hide();
            return;
        };
        if !card.visible {
            self.hide();
            return;
        }
        let size = self.window.inner_size();
        let Ok(viewport) = Viewport::new(size.width, size.height, self.window.scale_factor())
        else {
            self.hide();
            return;
        };
        let bounds = card.bounds();
        let Ok(origin) = WorldPoint::new(bounds.origin().x() + 3.0, bounds.origin().y() + 30.0)
        else {
            self.hide();
            return;
        };
        let Ok(screen) = board.camera.world_to_screen(origin, viewport) else {
            self.hide();
            return;
        };
        let occluders = upper_occluders(&board.scene, self.id, board.camera, viewport);
        // SAFETY: both calls use the owned handle on its creating main thread,
        // while the Arc keeps the parent NSView alive.
        unsafe {
            desk_browser_set_occluders(
                self.handle.as_ptr(),
                occluders[0][0],
                occluders[0][1],
                occluders[0][2],
                occluders[0][3],
                occluders[1][0],
                occluders[1][1],
                occluders[1][2],
                occluders[1][3],
            );
            desk_browser_set_frame(
                self.handle.as_ptr(),
                screen.x(),
                screen.y(),
                bounds.width() - 6.0,
                bounds.height() - 33.0,
                board.camera.zoom(),
                viewport.width(),
                viewport.height(),
            );
        }
    }
}

impl Drop for Browser {
    fn drop(&mut self) {
        // SAFETY: create returned this uniquely owned handle; it is destroyed once
        // on the main thread before the retained window is dropped.
        unsafe {
            desk_browser_destroy(self.handle.as_ptr());
        }
    }
}

fn upper_occluders(
    scene: &Scene,
    id: WindowId,
    camera: desk_core::Camera,
    viewport: Viewport,
) -> [[f64; 4]; 2] {
    let mut result = [[0.0; 4]; 2];
    let windows = scene.windows();
    let Some((index, card)) = windows.iter().enumerate().find(|(_, card)| card.id() == id) else {
        return result;
    };
    let zoom = camera.zoom();
    let center = camera.center();
    let mut count = 0;
    for (other_index, other) in windows.iter().enumerate() {
        if !other.visible || (other.z, other_index) <= (card.z, index) {
            continue;
        }
        let b = other.bounds();
        let x = (b.origin().x() - center.x()).mul_add(zoom, viewport.width() / 2.0);
        let y = (b.origin().y() - center.y()).mul_add(zoom, viewport.height() / 2.0);
        let right = b.width().mul_add(zoom, x).clamp(0.0, viewport.width());
        let bottom = b.height().mul_add(zoom, y).clamp(0.0, viewport.height());
        let left = x.clamp(0.0, viewport.width());
        let top = y.clamp(0.0, viewport.height());
        if right > left && bottom > top && count < result.len() {
            result[count] = [left, top, right - left, bottom - top];
            count += 1;
        }
    }
    result
}

pub fn add_card(
    board: &mut Board,
    browsers: &mut Vec<Browser>,
    window: Arc<Window>,
) -> Result<bool> {
    if browsers.len() >= MAX_CARDS {
        return Ok(false);
    }
    let id = WindowId(u64::try_from(browsers.len())?);
    let next = card(id.0)?;
    let browser = Browser::new(window, id)?;
    board.scene.add(next)?;
    browsers.push(browser);
    board.selected = Some(id);
    board.fit_all();
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn occluders_follow_z_visibility_and_include_full_upper_card() -> Result<()> {
        let mut scene = scene()?;
        let camera = desk_core::Camera::new(WorldPoint::new(0.0, 0.0)?, 1.0)?;
        let viewport = Viewport::new(1200, 800, 1.0)?;
        scene.drag(WindowId(1), -41.0, 0.0)?;
        let lower = upper_occluders(&scene, WindowId(0), camera, viewport);
        assert_eq!(lower[0], [579.0, 140.0, 560.0, 520.0]);
        assert_eq!(lower[1], [0.0; 4]);
        scene.add(card(2)?)?;
        scene.drag(WindowId(2), -600.0, 0.0)?;
        assert_ne!(
            upper_occluders(&scene, WindowId(0), camera, viewport)[1],
            [0.0; 4]
        );
        scene.raise(WindowId(0))?;
        assert_eq!(
            upper_occluders(&scene, WindowId(0), camera, viewport),
            [[0.0; 4]; 2]
        );
        scene.set_visible(WindowId(0), false)?;
        assert_eq!(
            upper_occluders(&scene, WindowId(1), camera, viewport)[1],
            [0.0; 4]
        );
        Ok(())
    }
}
