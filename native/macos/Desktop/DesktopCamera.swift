import AppKit
import Foundation

struct DesktopCameraSnapshot: Equatable, Sendable {
  var origin = CGPoint.zero
  var page = 0
  var paused = false
  var detail: String?
  var recoveryCount = 0
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
