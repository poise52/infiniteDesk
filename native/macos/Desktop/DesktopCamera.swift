import AppKit
import Foundation

struct DesktopCameraSnapshot: Equatable, Sendable {
  var origin = CGPoint.zero
  var page = 0
  var paused = false
  var detail: String?
  var recoveryCount = 0
  var requiresRestoration = false
  var recoveryInstructions: String?
  var focusTargetID: UUID?
}

struct DesktopCameraDisplay: Equatable, Sendable {
  let id: UInt32
  let frame: CGRect
  let visibleFrame: CGRect

  @MainActor static func current() -> Self? {
    guard NSScreen.screens.count == 1, let screen = NSScreen.screens.first,
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return nil }
    let top = screen.frame.maxY
    let visible = screen.visibleFrame
    return Self(id: number.uint32Value, frame: CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height),
      visibleFrame: CGRect(x: visible.minX, y: top - visible.maxY, width: visible.width, height: visible.height))
  }

  func origin(page: Int) -> CGPoint { CGPoint(x: CGFloat(page) * frame.width, y: 0) }
}

func desktopFramesEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 1) -> Bool {
  abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
    && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
}

func desktopWindowOnCurrentSpace(pid: pid_t, frame: CGRect) -> Bool {
  guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] else { return false }
  return windows.filter { info in
    guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
      (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
      let bounds = info[kCGWindowBounds as String] as? NSDictionary,
      let candidate = CGRect(dictionaryRepresentation: bounds)
    else { return false }
    return desktopFramesEqual(frame, candidate)
  }.count == 1
}

struct DesktopPanMetrics: Encodable, Sendable {
  struct Timing: Encodable, Sendable {
    var count = 0
    var samplesMS: [Double] = []
    var p50MS: Double { percentile(0.50) }
    var p95MS: Double { percentile(0.95) }
    var p99MS: Double { percentile(0.99) }

    private enum CodingKeys: String, CodingKey { case count, samplesMS, p50MS, p95MS, p99MS }
    func encode(to encoder: Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(count, forKey: .count)
      try values.encode(samplesMS, forKey: .samplesMS)
      try values.encode(p50MS, forKey: .p50MS)
      try values.encode(p95MS, forKey: .p95MS)
      try values.encode(p99MS, forKey: .p99MS)
    }
    mutating func append(_ milliseconds: Double) {
      count += 1
      if samplesMS.count == 512 { samplesMS.removeFirst() }
      samplesMS.append(milliseconds)
    }
    private func percentile(_ fraction: Double) -> Double {
      let sorted = samplesMS.sorted()
      guard !sorted.isEmpty else { return 0 }
      return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }
  }
  let timingDefinition = "Worker: serial AX batch including readback and durability. Delivery: dispatch through main-actor completion. Samples contain successful applied batches only; most recent 512 per kind."
  var coalescedPackets = 0
  var failedBatches = 0
  var continuousWorker = Timing()
  var continuousDelivery = Timing()
  var discreteWorker = Timing()
  var discreteDelivery = Timing()
}
