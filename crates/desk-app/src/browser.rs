use std::{ffi::c_void, marker::PhantomData, ptr::NonNull, rc::Rc, sync::Arc};

use anyhow::{Context, Result, bail};
use desk_core::{Scene, Viewport, Window as Card, WindowId, WorldPoint, WorldRect};
use winit::{
    raw_window_handle::{HasWindowHandle, RawWindowHandle},
    window::Window,
};

use crate::interaction::Board;

unsafe extern "C" {
    fn desk_browser_create(parent: *mut c_void) -> *mut c_void;
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
    scene.add(Card::new(
        WindowId(0),
        "Window · drag header to move".into(),
        WorldRect::new(WorldPoint::new(-450.0, -325.0)?, 900.0, 650.0)?,
        [90, 130, 120, 255],
        0,
    ))?;
    Ok(scene)
}

#[derive(PartialEq, Eq)]
pub enum Mode {
    Board,
    Browser,
}

pub struct Browser {
    handle: NonNull<c_void>,
    window: Arc<Window>,
    _main_thread: PhantomData<Rc<()>>,
}

impl Browser {
    pub fn new(window: Arc<Window>) -> Result<Self> {
        let handle = window
            .window_handle()
            .context("failed to get native window")?;
        let RawWindowHandle::AppKit(handle) = handle.as_raw() else {
            bail!("browser requires an AppKit window");
        };
        // SAFETY: winit supplies a live NSView on the main thread. The Arc keeps its
        // window alive until the browser is detached in Drop.
        let browser = unsafe { desk_browser_create(handle.ns_view.as_ptr()) };
        let handle = NonNull::new(browser).context("failed to create native browser")?;
        Ok(Self {
            handle,
            window,
            _main_thread: PhantomData,
        })
    }

    pub fn update(&mut self, board: &Board) {
        let Some(card) = board.scene.get(WindowId(0)) else {
            return;
        };
        let size = self.window.inner_size();
        let Ok(viewport) = Viewport::new(size.width, size.height, self.window.scale_factor())
        else {
            return;
        };
        let bounds = card.bounds();
        let Ok(origin) = WorldPoint::new(bounds.origin().x() + 3.0, bounds.origin().y() + 30.0)
        else {
            return;
        };
        let Ok(screen) = board.camera.world_to_screen(origin, viewport) else {
            return;
        };
        // SAFETY: the handle is owned by this object and all calls occur on the main
        // thread while its NSView and window remain alive.
        unsafe {
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
