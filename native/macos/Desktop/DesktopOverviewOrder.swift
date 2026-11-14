import CoreGraphics
import Foundation

func desktopOverviewWindowOrder(windows: [DesktopWindow], origin: CGPoint) -> [UUID] {
  guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] else { return [] }
  let candidates = Dictionary(grouping: windows.filter { $0.availability == .available && !$0.managerMinimized },
    by: \.pid)
  var result: [UUID] = []
  for entry in entries.reversed() {
    guard let pid = entry[kCGWindowOwnerPID as String] as? NSNumber, let registered = candidates[pid.int32Value],
      (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
      let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
      let frame = CGRect(dictionaryRepresentation: bounds)
    else { continue }
    let matches = registered.filter { desktopFramesEqual($0.worldFrame.offsetBy(dx: -origin.x, dy: -origin.y), frame) }
    if matches.count == 1 { result.append(matches[0].id) }
  }
  return result
}
