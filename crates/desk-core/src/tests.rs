use std::collections::HashSet;

use super::*;
use proptest::prelude::*;

fn point(x: f64, y: f64) -> Result<WorldPoint, GeometryError> {
    WorldPoint::new(x, y)
}
fn logical(x: f64, y: f64) -> Result<LogicalPoint, GeometryError> {
    LogicalPoint::new(x, y)
}
fn rect(x: f64, y: f64, width: f64, height: f64) -> Result<WorldRect, GeometryError> {
    WorldRect::new(point(x, y)?, width, height)
}
fn window(id: u64, bounds: WorldRect, z: i64) -> Window {
    Window::new(WindowId(id), format!("{id}"), bounds, [0, 0, 0, 255], z)
}
fn close(a: f64, b: f64, tolerance: f64) -> bool {
    (a - b).abs() <= tolerance
}

proptest! {
    #[test]
    fn transforms_round_trip(cx in -1e7f64..1e7, cy in -1e7f64..1e7, sx in 0.0f64..1920.0, sy in 0.0f64..1080.0, zoom in 0.05f64..20.0) {
        let v = Viewport::new(1920, 1080, 1.0).map_err(|e| TestCaseError::fail(e.to_string()))?;
        let center = point(cx, cy).map_err(|e| TestCaseError::fail(e.to_string()))?;
        let camera = Camera::new(center, zoom).map_err(|e| TestCaseError::fail(e.to_string()))?;
        let screen = logical(sx, sy).map_err(|e| TestCaseError::fail(e.to_string()))?;
        let world = camera.screen_to_world(screen, v).map_err(|e| TestCaseError::fail(e.to_string()))?;
        let result = camera.world_to_screen(world, v).map_err(|e| TestCaseError::fail(e.to_string()))?;
        prop_assert!(close(screen.x(), result.x(), 2e-8));
        prop_assert!(close(screen.y(), result.y(), 2e-8));
    }

    #[test]
    fn zoom_preserves_cursor_world_point(cx in -1e6f64..1e6, cy in -1e6f64..1e6, sx in 0.0f64..1000.0, sy in 0.0f64..800.0, old in 0.1f64..10.0, new in 0.1f64..10.0) {
        let v = Viewport::new(1000, 800, 1.0).map_err(|e| TestCaseError::fail(e.to_string()))?;
        let mut camera = Camera::new(point(cx,cy).map_err(|e| TestCaseError::fail(e.to_string()))?, old).map_err(|e| TestCaseError::fail(e.to_string()))?;
        let cursor = logical(sx,sy).map_err(|e| TestCaseError::fail(e.to_string()))?;
        let before = camera.screen_to_world(cursor,v).map_err(|e| TestCaseError::fail(e.to_string()))?;
        camera.zoom_at(new,cursor,v).map_err(|e| TestCaseError::fail(e.to_string()))?;
        let after = camera.screen_to_world(cursor,v).map_err(|e| TestCaseError::fail(e.to_string()))?;
        prop_assert!(close(before.x(), after.x(), 1e-9));
        prop_assert!(close(before.y(), after.y(), 1e-9));
    }

    #[test]
    fn culling_matches_intersection_area(x in -200.0f64..200.0, y in -200.0f64..200.0, w in 0.1f64..100.0, h in 0.1f64..100.0) {
        let bounds = rect(x,y,w,h).map_err(|e| TestCaseError::fail(e.to_string()))?;
        let area = rect(-25.0,-40.0,50.0,80.0).map_err(|e| TestCaseError::fail(e.to_string()))?;
        let mut scene = Scene::default();
        scene.add(window(1,bounds,0)).map_err(|e| TestCaseError::fail(e.to_string()))?;
        let overlap_x = (x+w).min(25.0) - x.max(-25.0);
        let overlap_y = (y+h).min(40.0) - y.max(-40.0);
        prop_assert_eq!(scene.visible(area).count() == 1, overlap_x > 0.0 && overlap_y > 0.0);
    }
}

#[test]
fn half_open_edges_visibility_and_z_order_survive_removal() -> Result<(), GeometryError> {
    let mut scene = Scene::default();
    let bounds = rect(0.0, 0.0, 10.0, 10.0)?;
    scene.add(window(1, bounds, 5))?;
    scene.add(window(2, bounds, 5))?;
    scene.add(window(3, bounds, 5))?;
    assert_eq!(
        scene.hit_test(point(0.0, 0.0)?).map(|w| w.id),
        Some(WindowId(3))
    );
    assert_eq!(scene.hit_test(point(10.0, 5.0)?), None);
    assert!(!bounds.intersects(rect(10.0, 0.0, 4.0, 4.0)?));
    assert!(scene.remove(WindowId(1)).is_some());
    assert_eq!(
        scene.hit_test(point(5.0, 5.0)?).map(|w| w.id),
        Some(WindowId(3))
    );
    scene.set_visible(WindowId(3), false)?;
    assert_eq!(
        scene.hit_test(point(5.0, 5.0)?).map(|w| w.id),
        Some(WindowId(2))
    );
    assert_eq!(scene.visible(bounds).count(), 1);
    Ok(())
}

#[test]
fn hit_test_tracks_z_changes() -> Result<(), GeometryError> {
    let mut scene = Scene::default();
    let bounds = rect(0.0, 0.0, 10.0, 10.0)?;
    scene.add(window(1, bounds, 100))?;
    scene.add(window(2, bounds, 1))?;
    let cursor = point(5.0, 5.0)?;
    assert_eq!(scene.hit_test(cursor).map(Window::id), Some(WindowId(1)));
    scene.set_z(WindowId(2), 101)?;
    assert_eq!(scene.hit_test(cursor).map(Window::id), Some(WindowId(2)));
    scene.set_z(WindowId(2), -1)?;
    assert_eq!(scene.hit_test(cursor).map(Window::id), Some(WindowId(1)));
    assert_eq!(
        scene.set_z(WindowId(3), 0),
        Err(GeometryError::UnknownWindow)
    );
    Ok(())
}

#[test]
fn pan_zoom_drag_and_invalid_operations_are_atomic() -> Result<(), GeometryError> {
    let viewport = Viewport::new(1200, 800, 2.0)?;
    let mut camera = Camera::new(point(10.0, 20.0)?, 2.0)?;
    camera.pan(logical(30.0, -10.0)?)?;
    assert_eq!(camera.center(), point(25.0, 15.0)?);
    let before = camera;
    assert!(
        camera
            .zoom_at(f64::NAN, logical(1.0, 1.0)?, viewport)
            .is_err()
    );
    assert_eq!(camera, before);
    let mut scene = Scene::default();
    scene.add(window(1, rect(1.0, 2.0, 30.0, 40.0)?, 0))?;
    assert_eq!(
        scene.add(window(1, rect(1.0, 2.0, 30.0, 40.0)?, 0)),
        Err(GeometryError::DuplicateId)
    );
    scene.drag(WindowId(1), 7.0, -3.0)?;
    assert_eq!(scene.windows()[0].bounds().origin(), point(8.0, -1.0)?);
    let before = scene.windows()[0].bounds();
    assert!(scene.drag(WindowId(1), f64::INFINITY, 0.0).is_err());
    assert_eq!(scene.windows()[0].bounds(), before);
    assert_eq!(
        scene.drag(WindowId(2), 0.0, 0.0),
        Err(GeometryError::UnknownWindow)
    );
    Ok(())
}

#[test]
fn hidpi_resize_and_numeric_limits() -> Result<(), GeometryError> {
    let viewport = Viewport::new(2400, 1600, 2.0)?;
    let physical = viewport.to_physical(logical(20.5, 30.0)?);
    assert_eq!(physical, PhysicalPoint { x: 41.0, y: 60.0 });
    assert_eq!(viewport.to_logical(physical)?, logical(20.5, 30.0)?);
    let camera = Camera::new(point(0.0, 0.0)?, 1.0)?;
    assert_eq!(
        camera.world_to_screen(point(0.0, 0.0)?, viewport)?,
        logical(600.0, 400.0)?
    );
    let resized = Viewport::new(1200, 800, 2.0)?;
    assert_eq!(
        camera.world_to_screen(point(0.0, 0.0)?, resized)?,
        logical(300.0, 200.0)?
    );
    assert!(Viewport::new(0, 800, 2.0).is_err());
    assert!(Viewport::new(800, 800, f64::NAN).is_err());
    assert!(point(f64::NAN, 0.0).is_err());
    assert!(point(MAX_WORLD + 1.0, 0.0).is_err());
    assert!(rect(0.0, 0.0, 0.0, 1.0).is_err());
    assert!(rect(MAX_WORLD, 0.0, 1.0, 1.0).is_err());
    assert!(Camera::new(point(0.0, 0.0)?, 0.0).is_err());
    assert!(Camera::new(point(0.0, 0.0)?, MAX_ZOOM * 2.0).is_err());
    Ok(())
}

#[test]
fn large_world_coordinates_are_transformed_relative_to_camera() -> Result<(), GeometryError> {
    let viewport = Viewport::new(1600, 1200, 2.0)?;
    let camera = Camera::new(point(900_000_000_000.0, -900_000_000_000.0)?, 4.0)?;
    let world = point(900_000_000_000.25, -899_999_999_999.5)?;
    let screen = camera.world_to_screen(world, viewport)?;
    assert_eq!(screen, logical(401.0, 302.0)?);
    assert_eq!(camera.screen_to_world(screen, viewport)?, world);
    Ok(())
}

#[test]
fn demo_is_seeded_unique_and_survives_repeated_operations() -> Result<(), GeometryError> {
    for count in [100, 1000, 5000, 10_000] {
        let mut scene = Scene::demo(count, 42)?;
        assert_eq!(scene.windows(), Scene::demo(count, 42)?.windows());
        let ids: HashSet<_> = scene.windows().iter().map(|w| w.id).collect();
        assert_eq!(ids.len(), count);
        let mut camera = Camera::new(point(0.0, 0.0)?, 1.0)?;
        let viewport = Viewport::new(1920, 1080, 2.0)?;
        for i in 0..100 {
            camera.pan(logical(5.0, -3.0)?)?;
            camera.zoom_at(
                if i % 2 == 0 { 1.5 } else { 1.0 },
                logical(200.0, 150.0)?,
                viewport,
            )?;
            let _visible = scene.visible(camera.bounds(viewport)?).count();
            scene.drag(
                WindowId(u64::try_from(i).map_err(|_| GeometryError::SceneSize)?),
                1.0,
                -1.0,
            )?;
        }
        assert_eq!(scene.windows().len(), count);
    }
    let mut scene = Scene::demo(10_000, 7)?;
    let mut camera = Camera::new(point(0.0, 0.0)?, 1.0)?;
    for i in 0..100_u32 {
        let id = WindowId(u64::from(i));
        let removed = scene.remove(id).ok_or(GeometryError::UnknownWindow)?;
        scene.add(removed)?;
        let viewport = Viewport::new(800 + i * 7, 600 + i * 5, 1.5)?;
        camera.zoom_at(
            if i % 2 == 0 { MIN_ZOOM } else { MAX_ZOOM },
            logical(400.0, 300.0)?,
            viewport,
        )?;
        let _ = scene.visible(camera.bounds(viewport)?).count();
    }
    assert_eq!(scene.windows().len(), 10_000);
    assert_ne!(
        Scene::demo(10, 42)?.windows(),
        Scene::demo(10, 43)?.windows()
    );
    assert!(Scene::demo(10_001, 0).is_err());
    Ok(())
}

#[test]
fn raise_normalizes_overflow_without_changing_other_ties() -> Result<(), GeometryError> {
    let bounds = rect(0.0, 0.0, 5.0, 5.0)?;
    let mut scene = Scene::default();
    for id in 0..3 {
        scene.add(window(id, bounds, i64::MAX))?;
    }
    scene.raise(WindowId(0))?;
    assert_eq!(
        scene.hit_test(point(1.0, 1.0)?).map(Window::id),
        Some(WindowId(0))
    );
    assert!(
        scene
            .get(WindowId(2))
            .ok_or(GeometryError::UnknownWindow)?
            .z
            > scene
                .get(WindowId(1))
                .ok_or(GeometryError::UnknownWindow)?
                .z
    );
    Ok(())
}
