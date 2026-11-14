@preconcurrency import ApplicationServices
import Foundation

// Cancellation is checked between AX calls; an AX call already in progress cannot be revoked.
final class FocusCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  // Accessed only by the serial AX queue, never by the main actor.
  var selectedElement: AXUIElement?
  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
  func isCancelled() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

enum FocusResult: Sendable {
  case verified(String)
  case failure(String)
}

func fixtureTextFocus(
  pid: pid_t, point: CGPoint, expectedFrame: CGRect, placeCaret: Bool, token: FocusCancellation
) -> FocusResult {
  func failure(_ step: String, _ error: AXError) -> FocusResult {
    .failure("\(step): AX error \(error.rawValue)")
  }
  guard !token.isCancelled() else { return .failure("cancelled") }
  guard case .rect(let rect, _) = fixtureAXRect(pid),
    abs(rect.minX - expectedFrame.minX) < 2, abs(rect.minY - expectedFrame.minY) < 2,
    abs(rect.width - expectedFrame.width) < 2, abs(rect.height - expectedFrame.height) < 2,
    rect.contains(point)
  else { return .failure("fixture geometry/identity unavailable or changed") }
  let app = AXUIElementCreateApplication(pid)
  var hit: AXUIElement?
  let hitError = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
  guard hitError == .success, let hit else { return failure("hit test", hitError) }
  var hitPID: pid_t = 0
  let pidError = AXUIElementGetPid(hit, &hitPID)
  guard pidError == .success, hitPID == pid else { return .failure("hit owner mismatch") }
  func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
  }
  guard let role = attribute(hit, kAXRoleAttribute as CFString) as? String,
    role == kAXTextAreaRole as String || role == kAXTextFieldRole as String
  else { return .failure("hit is not editable text") }
  guard let windowValue = attribute(hit, kAXWindowAttribute as CFString),
    CFGetTypeID(windowValue) == AXUIElementGetTypeID(),
    let topValue = attribute(hit, kAXTopLevelUIElementAttribute as CFString),
    CFGetTypeID(topValue) == AXUIElementGetTypeID()
  else { return .failure("hit window unavailable") }
  let window = windowValue as! AXUIElement
  guard CFEqual(window, topValue),
    (attribute(window, kAXIdentifierAttribute as CFString) as? String) == fixtureAXMainID
  else { return .failure("hit is outside fixture main window or in sheet") }
  if !placeCaret {
    guard let selected = token.selectedElement, CFEqual(hit, selected) else {
      return .failure("focused element changed from selected target")
    }
  }
  var requestedRange: CFRange?
  if placeCaret {
    var p = point
    guard let position = AXValueCreate(.cgPoint, &p) else { return .failure("position invalid") }
    var rangeValue: CFTypeRef?
    let rangeError = AXUIElementCopyParameterizedAttributeValue(
      hit, kAXRangeForPositionParameterizedAttribute as CFString, position, &rangeValue)
    guard rangeError == .success, let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
    else { return failure("range for position", rangeError) }
    var range = CFRange()
    guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0 else {
      return .failure("range for position invalid")
    }
    range.length = 0
    guard let selection = AXValueCreate(.cfRange, &range), !token.isCancelled() else {
      return .failure("cancelled or invalid selection")
    }
    let selectionError = AXUIElementSetAttributeValue(
      hit, kAXSelectedTextRangeAttribute as CFString, selection)
    guard selectionError == .success else { return failure("set selection", selectionError) }
    requestedRange = range
    guard !token.isCancelled() else { return .failure("cancelled") }
    let focusError = AXUIElementSetAttributeValue(
      hit, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard focusError == .success else { return failure("set focus", focusError) }
  }
  guard !token.isCancelled() else { return .failure("cancelled") }
  guard (attribute(hit, kAXFocusedAttribute as CFString) as? Bool) == true,
    let focused = attribute(app, kAXFocusedUIElementAttribute as CFString), CFEqual(hit, focused)
  else { return .failure("focused element/window not confirmed") }
  if let requestedRange {
    guard let selection = attribute(hit, kAXSelectedTextRangeAttribute as CFString),
      CFGetTypeID(selection) == AXValueGetTypeID()
    else { return .failure("selection readback unavailable") }
    var actual = CFRange()
    guard AXValueGetValue(selection as! AXValue, .cfRange, &actual),
      actual.location == requestedRange.location, actual.length == 0
    else { return .failure("selection readback mismatch") }
    token.selectedElement = hit
    return .verified("fixture AX focus and caret \(actual.location) confirmed")
  }
  return .verified("fixture AX selected element/window confirmed")
}
