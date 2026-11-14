import Foundation
import CoreGraphics

struct DesktopOverviewGeometry {
  private(set) var scale: CGFloat = 1
  private(set) var origin = CGPoint.zero

  func viewPoint(_ world: CGPoint) -> CGPoint {
    CGPoint(x: (world.x - origin.x) * scale, y: (world.y - origin.y) * scale)
  }

  func worldPoint(_ view: CGPoint) -> CGPoint {
    CGPoint(x: view.x / scale + origin.x, y: view.y / scale + origin.y)
  }

  func viewFrame(_ world: CGRect) -> CGRect {
    CGRect(origin: viewPoint(world.origin), size: CGSize(width: world.width * scale, height: world.height * scale))
  }

  mutating func fit(_ frames: [CGRect], in viewport: CGRect) {
    guard viewport.width > 0, viewport.height > 0 else { return }
    let usable = frames.filter(Self.valid)
    guard let first = usable.first else { return }
    let bounds = usable.dropFirst().reduce(first) { $0.union($1) }
    scale = max(1e-9, min(1, viewport.width / bounds.width, viewport.height / bounds.height))
    origin = CGPoint(x: bounds.midX - viewport.midX / scale, y: bounds.midY - viewport.midY / scale)
  }

  mutating func zoom(by factor: CGFloat, at anchor: CGPoint) {
    guard factor.isFinite, factor > 0 else { return }
    let worldAnchor = worldPoint(anchor)
    scale = max(1e-9, min(4, scale * factor))
    origin = CGPoint(x: worldAnchor.x - anchor.x / scale, y: worldAnchor.y - anchor.y / scale)
  }

  mutating func reveal(_ frame: CGRect, in viewport: CGRect) {
    guard Self.valid(frame) else { return }
    let projected = viewFrame(frame)
    if projected.width > viewport.width || projected.height > viewport.height {
      fit([frame], in: viewport)
      return
    }
    let x = projected.minX < viewport.minX ? projected.minX - viewport.minX
      : projected.maxX > viewport.maxX ? projected.maxX - viewport.maxX : 0
    let y = projected.minY < viewport.minY ? projected.minY - viewport.minY
      : projected.maxY > viewport.maxY ? projected.maxY - viewport.maxY : 0
    origin.x += x / scale
    origin.y += y / scale
  }

  static func valid(_ frame: CGRect) -> Bool {
    frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
      && frame.width > 0 && frame.height > 0 && frame.maxX.isFinite && frame.maxY.isFinite
  }
}

struct DesktopOverviewItem: Equatable {
  let id: UUID
  let frame: CGRect
  var selectable = true
}

enum DesktopOverviewDirection { case left, right, up, down }

enum DesktopOverviewSelection {
  static func cycle(from current: UUID?, by delta: Int, items: [DesktopOverviewItem]) -> UUID? {
    let available = items.filter(\.selectable)
    guard !available.isEmpty else { return nil }
    guard let index = available.firstIndex(where: { $0.id == current }) else {
      return delta < 0 ? available.last?.id : available.first?.id
    }
    return available[((index + delta) % available.count + available.count) % available.count].id
  }

  static func move(from current: UUID?, toward direction: DesktopOverviewDirection,
    items: [DesktopOverviewItem]) -> UUID? {
    let available = items.filter(\.selectable)
    guard let source = available.first(where: { $0.id == current }) else { return available.first?.id }
    var best: (id: UUID, score: CGFloat)?
    for candidate in available where candidate.id != source.id {
      let dx = candidate.frame.midX - source.frame.midX
      let dy = candidate.frame.midY - source.frame.midY
      let primary: CGFloat
      let lateral: CGFloat
      switch direction {
      case .left: primary = -dx; lateral = abs(dy)
      case .right: primary = dx; lateral = abs(dy)
      case .up: primary = -dy; lateral = abs(dx)
      case .down: primary = dy; lateral = abs(dx)
      }
      guard primary > 0 else { continue }
      let score = primary + lateral * 2
      if score < (best?.score ?? .infinity) { best = (candidate.id, score) }
    }
    return best?.id ?? source.id
  }
}
