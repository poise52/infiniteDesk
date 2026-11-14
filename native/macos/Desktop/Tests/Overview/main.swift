import Foundation
import CoreGraphics

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
  guard value() else { fatalError(message) }
}

func near(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.00001) -> Bool {
  abs(lhs - rhs) <= tolerance
}

func near(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat = 0.00001) -> Bool {
  near(lhs.x, rhs.x, tolerance: tolerance) && near(lhs.y, rhs.y, tolerance: tolerance)
}

let viewport = CGRect(x: 48, y: 94, width: 1100, height: 600)
let frames = [
  CGRect(x: -1700, y: -300, width: 900, height: 700),
  CGRect(x: 60, y: 30, width: 1100, height: 800),
  CGRect(x: 3500, y: 420, width: 600, height: 400),
]
var geometry = DesktopOverviewGeometry()
geometry.fit(frames, in: viewport)
for frame in frames {
  let projected = geometry.viewFrame(frame)
  expect(projected.minX >= viewport.minX - 0.001 && projected.maxX <= viewport.maxX + 0.001
    && projected.minY >= viewport.minY - 0.001 && projected.maxY <= viewport.maxY + 0.001,
    "Fit all must include windows on negative and distant offscreen pages")
  expect(near(geometry.worldPoint(geometry.viewPoint(frame.origin)), frame.origin),
    "World/view round-trip must preserve original coordinates")
}
let anchor = CGPoint(x: 817.25, y: 319.75)
let worldAnchor = geometry.worldPoint(anchor)
for index in 0..<200 {
  geometry.zoom(by: index.isMultiple(of: 2) ? 1.11 : 1 / 1.11, at: anchor)
  expect(near(geometry.worldPoint(anchor), worldAnchor), "Wheel and pinch zoom must stay anchored at pointer")
}
geometry.zoom(by: .greatestFiniteMagnitude, at: anchor)
expect(geometry.scale == 4 && near(geometry.worldPoint(anchor), worldAnchor),
  "Upper zoom bound must preserve the cursor anchor")
geometry.zoom(by: 1e-20, at: anchor)
expect(geometry.scale == 1e-9 && near(geometry.worldPoint(anchor), worldAnchor, tolerance: 0.001),
  "Lower zoom bound must preserve anchor within floating-point precision")
let savedScale = geometry.scale
let savedOrigin = geometry.origin
geometry.zoom(by: .nan, at: anchor)
geometry.zoom(by: -1, at: anchor)
expect(geometry.scale == savedScale && geometry.origin == savedOrigin,
  "Invalid gesture values cannot poison overview geometry")

geometry.fit([CGRect(x: 1e9, y: -1e9, width: 900, height: 700)], in: viewport)
let largeAnchor = geometry.worldPoint(anchor)
geometry.zoom(by: 1.25, at: anchor)
expect(near(largeAnchor, geometry.worldPoint(anchor), tolerance: 0.0001),
  "Zoom must remain stable far from the world origin")
geometry.fit([CGRect(x: 0, y: 0, width: 100, height: 100)], in: viewport)
expect(geometry.scale == 1, "Fit overview cannot enlarge a small original above 1:1")
let unchanged = geometry.origin
geometry.fit([CGRect(x: CGFloat.nan, y: 0, width: 20, height: 30), .zero], in: viewport)
expect(geometry.origin == unchanged, "Invalid or empty external window bounds cannot poison fit")

let target = CGRect(x: 3800, y: 900, width: 400, height: 250)
geometry.reveal(target, in: viewport)
let revealed = geometry.viewFrame(target)
expect(viewport.contains(revealed), "Keyboard selection must reveal a window after user zooms it outside the overview")
let originAfterReveal = geometry.origin
geometry.reveal(target, in: viewport)
expect(geometry.origin == originAfterReveal, "Revealing an already visible selection cannot move overview again")

let a = UUID(), b = UUID(), c = UUID(), d = UUID(), unavailable = UUID()
let overlap = CGRect(x: 0, y: 0, width: 100, height: 100)
let items = [
  DesktopOverviewItem(id: a, frame: overlap),
  DesktopOverviewItem(id: b, frame: overlap),
  DesktopOverviewItem(id: c, frame: CGRect(x: 200, y: 0, width: 100, height: 100)),
  DesktopOverviewItem(id: d, frame: CGRect(x: 0, y: -200, width: 100, height: 100)),
  DesktopOverviewItem(id: unavailable, frame: overlap, selectable: false),
]
expect(DesktopOverviewSelection.cycle(from: a, by: 1, items: items) == b,
  "Tab must reach both identical-position windows by exact ID")
expect(DesktopOverviewSelection.cycle(from: a, by: -1, items: items) == d,
  "Shift-Tab wraps and skips unavailable windows")
expect(DesktopOverviewSelection.cycle(from: d, by: 1, items: items) == a,
  "Forward cycle wraps to the first available window")
expect(DesktopOverviewSelection.move(from: a, toward: .right, items: items) == c,
  "Right selects the window to the right in world coordinates")
expect(DesktopOverviewSelection.move(from: c, toward: .left, items: items) == a,
  "Directional ties use stable registration order")
expect(DesktopOverviewSelection.move(from: a, toward: .up, items: items) == d,
  "Up uses the AX top-left world coordinate system")
expect(DesktopOverviewSelection.move(from: d, toward: .up, items: items) == d,
  "Arrow with no candidate preserves the exact current selection")
expect(DesktopOverviewSelection.cycle(from: nil, by: 1, items: []) == nil,
  "Empty or all-closed overview has no selectable UUID")
expect(DesktopOverviewSelection.cycle(from: nil, by: 1,
  items: [DesktopOverviewItem(id: unavailable, frame: overlap, selectable: false)]) == nil,
  "Unavailable originals cannot be activated")
print("Desktop overview tests passed: offscreen/negative fit, transforms, anchored zoom, large coordinates, reveal, exact UUID, overlap, directional and cyclic selection.")
