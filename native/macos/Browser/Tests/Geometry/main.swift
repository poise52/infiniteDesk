import AppKit
import Foundation

var checks = 0
@MainActor func check(_ condition: Bool, _ message: String) {
  guard condition else { fatalError(message) }
  checks += 1
}
@MainActor func near(_ actual: CGPoint?, _ expected: CGPoint, _ message: String) {
  guard let actual else { fatalError(message + ": point unavailable") }
  check(abs(actual.x - expected.x) < 0.000001 && abs(actual.y - expected.y) < 0.000001, message)
}
func geometry(
  image: CGSize = CGSize(width: 1600, height: 1200),
  content: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
  source: CGRect = CGRect(x: -1200, y: 200, width: 1600, height: 1200),
  scale: CGFloat = 2, reduction: CGFloat = 0.5
) -> CaptureFrameGeometry {
  guard
    let result = CaptureFrameGeometry(
      imageSize: image, contentRect: content,
      screenRect: source, scaleFactor: scale, contentScale: reduction)
  else { fatalError("valid fixture geometry rejected") }
  return result
}

let frame = geometry()
let wide = CGRect(x: 0, y: 0, width: 1000, height: 600)
near(
  frame.normalizedPoint(CGPoint(x: 100, y: 600), in: wide, flipped: false), .zero,
  "unflipped top-left with pillarboxing")
near(
  frame.normalizedPoint(CGPoint(x: 500, y: 300), in: wide, flipped: false),
  CGPoint(x: 0.5, y: 0.5), "unflipped center")
near(
  frame.normalizedPoint(CGPoint(x: 100, y: 0), in: wide, flipped: true), .zero,
  "flipped top-left")
check(
  frame.normalizedPoint(CGPoint(x: 50, y: 300), in: wide, flipped: false) == nil,
  "outer pillarbox rejected")
check(
  frame.normalizedPoint(CGPoint(x: 900, y: 300), in: wide, flipped: false) == nil,
  "right boundary rejected")
check(
  frame.normalizedPoint(CGPoint(x: 500, y: 0), in: wide, flipped: false) == nil,
  "bottom boundary rejected")
let tall = CGRect(x: 20, y: 30, width: 400, height: 500)
near(
  frame.normalizedPoint(CGPoint(x: 20, y: 130), in: tall, flipped: true), .zero,
  "nonzero-origin top letterbox")
check(
  frame.normalizedPoint(CGPoint(x: 220, y: 70), in: tall, flipped: true) == nil,
  "outer letterbox rejected")
let padded = geometry(
  content: CGRect(x: 40, y: 30, width: 720, height: 540),
  source: CGRect(x: 200, y: 100, width: 1440, height: 1080))
near(
  padded.normalizedPoint(
    CGPoint(x: 80, y: 60),
    in: CGRect(x: 0, y: 0, width: 1600, height: 1200), flipped: true), .zero,
  "SCK inner padding removed before normalization")
check(
  padded.normalizedPoint(
    CGPoint(x: 20, y: 300),
    in: CGRect(x: 0, y: 0, width: 1600, height: 1200), flipped: true) == nil,
  "SCK inner padding rejected")
check(
  frame.normalizedPoint(CGPoint(x: CGFloat.nan, y: 0), in: wide, flipped: true) == nil,
  "nonfinite click rejected")
check(
  CaptureFrameGeometry(
    imageSize: .zero, contentRect: .zero, screenRect: .zero,
    scaleFactor: 0, contentScale: 0) == nil, "degenerate geometry rejected")
check(
  CaptureFrameGeometry(
    imageSize: CGSize(width: 100, height: 100),
    contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
    screenRect: CGRect(x: 0, y: 0, width: 400, height: 400),
    scaleFactor: 2, contentScale: 0.5) == nil, "inconsistent geometry rejected")

@MainActor final class Flipped: NSView { override var isFlipped: Bool { true } }
MainActor.assumeIsolated {
  guard
    let visible = browserVisibleGeometry(
      x: -100, y: -50, width: 800, height: 644,
      zoom: 0.5, viewportWidth: 600, viewportHeight: 400)
  else { fatalError("clipped card") }
  let root = Flipped(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
  let surface = Flipped(frame: visible.frame)
  surface.bounds = visible.bounds
  root.addSubview(surface)
  let preview = NSView(frame: CGRect(x: 0, y: 44, width: 800, height: 600))
  surface.addSubview(preview)
  // Root coordinates include camera zoom and clipping; NSView handles both before mapping.
  let center = preview.convert(CGPoint(x: 100, y: 122), from: root)
  near(
    frame.normalizedPoint(center, in: preview.bounds, flipped: preview.isFlipped),
    CGPoint(x: 0.5, y: 0.5), "clipped and zoomed flipped ancestor to unflipped preview")
}
MainActor.assumeIsolated {
  let card = CGRect(x: 100, y: 80, width: 600, height: 400)
  let blocker = CGRect(x: 500, y: 200, width: 300, height: 300)
  let pieces = browserUncoveredRectangles(card, occluders: [blocker])
  check(
    pieces.allSatisfy { $0.intersection(blocker).isEmpty }, "native target excludes upper cards")
  check(pieces.allSatisfy { card.contains($0) }, "native target stays inside visible card")
  check(
    browserUncoveredRectangles(card, occluders: [card]).isEmpty,
    "fully covered card has no native target")
  check(browserRectArea(.null) == 0, "disjoint display intersection has zero area")
  let root = Flipped(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
  let surface = Flipped(frame: CGRect(x: 100, y: 80, width: 600, height: 400))
  surface.bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
  root.addSubview(surface)
  let content = CGRect(x: 0, y: 52, width: 600, height: 320)
  let before = root.convert(content, from: surface)
  surface.frame.origin = CGPoint(x: 250, y: 150)
  let after = root.convert(content, from: surface)
  check(
    after.minX - before.minX == 150 && after.minY - before.minY == 70,
    "reopening computes current card position after canvas pan or drag")
  surface.frame = CGRect(x: -100, y: -50, width: 300, height: 200)
  surface.bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
  let clipped = root.convert(content, from: surface).intersection(root.bounds)
  check(
    clipped == CGRect(x: 0, y: 0, width: 200, height: 136),
    "zoomed partial native area clips to the current viewport")
  let valid = CGRect(x: 200, y: 100, width: 400, height: 300)
  check(
    browserLargestNativeFrame(
      candidates: [CGRect(x: -1000, y: 0, width: 1200, height: 500), valid],
      displays: [CGRect(x: 0, y: 0, width: 1200, height: 800)]) == valid,
    "largest pre-clipped sliver cannot hide a valid native target")
  check(
    browserLargestNativeFrame(
      candidates: [CGRect(x: 0, y: 0, width: 800, height: 300)],
      displays: [CGRect(x: 0, y: 0, width: 300, height: 800)]) == nil,
    "minimum size applies after display clipping")
  let secondary = CGRect(x: -1400, y: -700, width: 800, height: 500)
  check(
    nativeAXFrame(fromAppKit: secondary, primaryScreenMaxY: 900)
      == CGRect(x: -1400, y: 1100, width: 800, height: 500),
    "negative secondary-monitor origin converts using the primary display")
}
MainActor.assumeIsolated {
  let applications = [
    NativeWindowApplication(id: 100, appName: "Chrome", suggested: true, launchDate: nil),
    NativeWindowApplication(id: 200, appName: "Chrome", suggested: false, launchDate: nil),
    NativeWindowApplication(id: 300, appName: "Finder", suggested: false, launchDate: nil),
  ]
  check(
    browserNativeApplicationLabels(applications)
      == ["Chrome · PID 100 · recent", "Chrome · PID 200", "Finder"],
    "only duplicate application labels include a process identifier")
  let choices = [
    NativeWindowChoice(
      id: UUID(), appName: "Chrome", title: "Same", pid: 100,
      frame: CGRect(x: 10, y: 20, width: 800, height: 600), launchDate: nil),
    NativeWindowChoice(
      id: UUID(), appName: "Chrome", title: "Same", pid: 100,
      frame: CGRect(x: -900, y: 40, width: 700, height: 500), launchDate: nil),
    NativeWindowChoice(
      id: UUID(), appName: "Chrome", title: "Unique", pid: 100,
      frame: CGRect(x: 20, y: 40, width: 600, height: 400), launchDate: nil),
  ]
  check(
    browserNativeWindowLabels(choices)
      == ["Same · 10,20 · 800×600", "Same · -900,40 · 700×500", "Unique"],
    "only duplicate window titles include their native geometry")
  check(
    browserNativeWindowLabels([choices[0], choices[0]])
      == ["Same · 10,20 · 800×600 · #1", "Same · 10,20 · 800×600 · #2"],
    "same-title same-frame windows remain distinct in the chooser")
}
print("PASS: \(checks) capture/native geometry and chooser checks")
