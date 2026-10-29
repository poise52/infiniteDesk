use bytemuck::{Pod, Zeroable};
use desk_core::{Camera, Scene, Viewport, WindowId, WorldRect};

#[repr(C)]
#[derive(Debug, Clone, Copy, Pod, Zeroable)]
pub struct Instance {
    pub rect: [f32; 4],
    pub color: [f32; 4],
    pub depth: f32,
    pub padding: [f32; 3],
}

#[derive(Debug, Clone, Copy)]
pub struct Label {
    pub index: usize,
    pub left: f32,
    pub top: f32,
    pub bounds: [i32; 4],
    pub depth: f32,
}

#[allow(clippy::cast_possible_truncation)]
fn clipped(rect: [f64; 4], camera: Camera, viewport: Viewport) -> Option<[f32; 4]> {
    let scale = viewport.scale();
    let x = |world: f64| {
        ((world - camera.center().x()).mul_add(camera.zoom(), viewport.width() / 2.0)) * scale
    };
    let y = |world: f64| {
        ((world - camera.center().y()).mul_add(camera.zoom(), viewport.height() / 2.0)) * scale
    };
    let right = viewport.width() * scale;
    let bottom = viewport.height() * scale;
    let x0 = x(rect[0]).clamp(0.0, right);
    let y0 = y(rect[1]).clamp(0.0, bottom);
    let x1 = x(rect[2]).clamp(0.0, right);
    let y1 = y(rect[3]).clamp(0.0, bottom);
    if x1 <= x0 || y1 <= y0 {
        return None;
    }
    Some([x0 as f32, y0 as f32, x1 as f32, y1 as f32])
}

fn push_rect(
    instances: &mut Vec<Instance>,
    rect: [f64; 4],
    color: [f32; 4],
    depth: f32,
    camera: Camera,
    viewport: Viewport,
) {
    if let Some(rect) = clipped(rect, camera, viewport) {
        instances.push(Instance {
            rect,
            color,
            depth,
            padding: [0.0; 3],
        });
    }
}

#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_precision_loss,
    clippy::too_many_lines
)]
pub fn prepare(
    scene: &Scene,
    camera: Camera,
    viewport: Viewport,
    selection: Option<WindowId>,
    visible: &mut Vec<usize>,
    instances: &mut Vec<Instance>,
    labels: &mut Vec<Label>,
) -> Result<(), desk_core::GeometryError> {
    visible.clear();
    instances.clear();
    labels.clear();
    let area = camera.bounds(viewport)?;
    visible.extend(
        scene
            .windows()
            .iter()
            .enumerate()
            .filter(|(_, w)| w.visible && w.bounds().intersects(area))
            .map(|(index, _)| index),
    );
    visible.sort_unstable_by_key(|index| (scene.windows()[*index].z, *index));
    let count = visible.len();
    for (rank, &index) in visible.iter().enumerate() {
        let window = &scene.windows()[index];
        let b: WorldRect = window.bounds();
        let x = b.origin().x();
        let y = b.origin().y();
        let r = x + b.width();
        let bottom = y + b.height();
        let border = 1.0_f64.min(b.width() / 2.0).min(b.height() / 2.0);
        let header = (y + 30.0).min(bottom - border);
        let depth = 1.0 - (rank + 1) as f32 / (count + 1) as f32;
        let edge = if selection == Some(window.id()) {
            [0.10, 0.34, 0.32, 1.0]
        } else {
            [0.10, 0.12, 0.12, 1.0]
        };
        let shade = f32::from(window.color[0]) / 255.0 * 0.008;
        push_rect(instances, [x, y, r, bottom], edge, depth, camera, viewport);
        push_rect(
            instances,
            [x + border, y + border, r - border, bottom - border],
            [0.045 + shade, 0.052 + shade, 0.055 + shade, 1.0],
            depth,
            camera,
            viewport,
        );
        push_rect(
            instances,
            [x + border, y + border, r - border, header],
            [0.075 + shade, 0.085 + shade, 0.088 + shade, 1.0],
            depth,
            camera,
            viewport,
        );
        let title = [x + 10.0, y + 6.0, r - 8.0, header];
        if let Some(clip) = clipped(title, camera, viewport) {
            let sx = ((title[0] - camera.center().x())
                .mul_add(camera.zoom(), viewport.width() / 2.0))
                * viewport.scale();
            let sy = ((title[1] - camera.center().y())
                .mul_add(camera.zoom(), viewport.height() / 2.0))
                * viewport.scale();
            if camera.zoom() * viewport.scale() >= 0.4 {
                labels.push(Label {
                    index,
                    left: sx as f32,
                    top: sy as f32,
                    bounds: [
                        clip[0] as i32,
                        clip[1] as i32,
                        clip[2].ceil() as i32,
                        clip[3].ceil() as i32,
                    ],
                    depth,
                });
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use desk_core::{GeometryError, Window, WorldPoint};

    #[test]
    fn clips_before_conversion_and_preserves_header() -> Result<(), GeometryError> {
        let mut scene = Scene::default();
        let bounds = WorldRect::new(
            WorldPoint::new(-10_000_000_000.0, -10.0)?,
            20_000_000_000.0,
            100.0,
        )?;
        scene.add(Window::new(
            WindowId(1),
            "wide".into(),
            bounds,
            [0, 0, 0, 255],
            0,
        ))?;
        let camera = Camera::new(WorldPoint::new(0.0, 0.0)?, 100.0)?;
        let viewport = Viewport::new(1600, 1200, 2.0)?;
        let (mut visible, mut instances, mut labels) = (Vec::new(), Vec::new(), Vec::new());
        prepare(
            &scene,
            camera,
            viewport,
            None,
            &mut visible,
            &mut instances,
            &mut labels,
        )?;
        assert_eq!(visible, [0]);
        assert_eq!(instances.len(), 3);
        assert_eq!(instances[2].rect, [0.0, 0.0, 1600.0, 1200.0]);
        assert_eq!(instances[2].color, [0.075, 0.085, 0.088, 1.0]);
        Ok(())
    }

    #[test]
    fn visible_order_matches_hit_testing_and_retina_clipping() -> Result<(), GeometryError> {
        let mut scene = Scene::default();
        let bounds = WorldRect::new(WorldPoint::new(-5.0, -5.0)?, 10.0, 10.0)?;
        for (id, z) in [(1, 5), (2, 1), (3, 5)] {
            scene.add(Window::new(
                WindowId(id),
                id.to_string(),
                bounds,
                [0, 0, 0, 255],
                z,
            ))?;
        }
        let camera = Camera::new(WorldPoint::new(0.0, 0.0)?, 1.0)?;
        let viewport = Viewport::new(200, 100, 2.0)?;
        let (mut visible, mut instances, mut labels) = (Vec::new(), Vec::new(), Vec::new());
        prepare(
            &scene,
            camera,
            viewport,
            Some(WindowId(3)),
            &mut visible,
            &mut instances,
            &mut labels,
        )?;
        assert_eq!(visible, [1, 0, 2]);
        assert_eq!(
            scene.hit_test(WorldPoint::new(0.0, 0.0)?).map(Window::id),
            Some(WindowId(3))
        );
        assert_eq!(instances[0].rect, [90.0, 40.0, 110.0, 60.0]);
        assert!(instances[0].depth > instances[3].depth && instances[3].depth > instances[6].depth);
        assert_eq!(instances[6].color, [0.10, 0.34, 0.32, 1.0]);
        Ok(())
    }
}

#[cfg(test)]
mod stress_tests {
    use super::*;
    use desk_core::{GeometryError, WorldPoint};
    #[test]
    fn prepares_ten_thousand_visible_windows_with_text_lod() -> Result<(), GeometryError> {
        let scene = Scene::demo(10_000, 42)?;
        let camera = Camera::new(WorldPoint::new(0.0, 0.0)?, 0.01)?;
        let viewport = Viewport::new(2400, 1800, 1.0)?;
        let (mut visible, mut instances, mut labels) = (Vec::new(), Vec::new(), Vec::new());
        prepare(
            &scene,
            camera,
            viewport,
            None,
            &mut visible,
            &mut instances,
            &mut labels,
        )?;
        assert_eq!(visible.len(), 10_000);
        assert_eq!(instances.len(), 30_000);
        assert!(labels.is_empty());
        assert!(instances.first().map(|v| v.depth) > instances.last().map(|v| v.depth));
        Ok(())
    }
}
