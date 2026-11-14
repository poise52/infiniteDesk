import AppKit
@preconcurrency import ApplicationServices
import Foundation

// The lock protects cancellation and the single mutation claim, never AX IPC.
final class WindowTextGate: @unchecked Sendable {
  private let lock = NSLock()
  private var active = true
  private let deadline = DispatchTime.now() + .seconds(3)
  func isActive() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return active && DispatchTime.now() < deadline
  }
  func cancel() {
    lock.lock()
    active = false
    lock.unlock()
  }
  func commit(_ action: () -> AXError) -> AXError? {
    lock.lock()
    let claimed = active && DispatchTime.now() < deadline
    active = false
    lock.unlock()
    guard claimed else { return nil }
    return action()
  }
}

private func textAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
    return nil
  }
  return value
}

func isAllowedTextRole(_ role: String, subrole: String?, inWebArea: Bool) -> Bool {
  (role == kAXTextFieldRole || role == kAXTextAreaRole)
    && subrole != kAXSecureTextFieldSubrole && inWebArea
}

private func textRect(_ element: AXUIElement) -> CGRect? {
  guard let position = textAttribute(element, kAXPositionAttribute),
    let size = textAttribute(element, kAXSizeAttribute),
    CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
  else { return nil }
  var origin = CGPoint.zero
  var dimensions = CGSize.zero
  guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
    AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
    [origin.x, origin.y, dimensions.width, dimensions.height].allSatisfy(\.isFinite),
    dimensions.width > 0, dimensions.height > 0
  else { return nil }
  return CGRect(origin: origin, size: dimensions)
}

private func textTarget(_ app: AXUIElement, window: AXUIElement, gate: WindowTextGate)
  -> (AXUIElement, String)?
{
  guard gate.isActive(), let raw = textAttribute(app, kAXFocusedUIElementAttribute),
    CFGetTypeID(raw) == AXUIElementGetTypeID()
  else { return nil }
  let element = raw as! AXUIElement
  guard AXUIElementSetMessagingTimeout(element, 0.3) == .success,
    let role = textAttribute(element, kAXRoleAttribute) as? String
  else { return nil }
  var subroleValue: CFTypeRef?
  let subroleResult = AXUIElementCopyAttributeValue(
    element, kAXSubroleAttribute as CFString, &subroleValue)
  guard
    subroleResult == .success || subroleResult == .attributeUnsupported || subroleResult == .noValue
  else { return nil }
  guard subroleResult != .success || subroleValue is String else { return nil }
  let subrole = subroleValue as? String
  guard isAllowedTextRole(role, subrole: subrole, inWebArea: true) else { return nil }
  var settable = DarwinBoolean(false)
  guard
    AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
    settable.boolValue
  else { return nil }
  var current = element
  var inWebArea = false
  var reachedWindow = false
  for _ in 0..<64 {
    guard gate.isActive(), AXUIElementSetMessagingTimeout(current, 0.3) == .success else {
      return nil
    }
    if CFEqual(current, window) {
      reachedWindow = true
      break
    }
    if (textAttribute(current, kAXRoleAttribute) as? String) == "AXWebArea" { inWebArea = true }
    guard let parent = textAttribute(current, kAXParentAttribute),
      CFGetTypeID(parent) == AXUIElementGetTypeID()
    else { return nil }
    current = parent as! AXUIElement
  }
  guard reachedWindow, isAllowedTextRole(role, subrole: subrole, inWebArea: inWebArea),
    let rect = textRect(element), let windowRect = textRect(window),
    !rect.intersection(windowRect).isNull, !rect.intersection(windowRect).isEmpty
  else { return nil }
  let title =
    (textAttribute(element, kAXTitleAttribute) as? String)
    ?? (textAttribute(element, kAXDescriptionAttribute) as? String) ?? "Unnamed field"
  return (element, String(title.prefix(120)))
}

// Immutable AX reference captured on the serial AX queue.
final class TextTarget: @unchecked Sendable {
  let element: AXUIElement
  let title: String
  init(element: AXUIElement, title: String) {
    self.element = element
    self.title = title
  }
}

func textAccessibilityAvailable() -> Bool { AXIsProcessTrusted() }

private let textQueue = DispatchQueue(label: "dev.infinitedesk.text-input", qos: .userInitiated)

@MainActor
func inspectTextTarget(
  identity: WindowFocusIdentity, app: NSRunningApplication, gate: WindowTextGate,
  completion: @escaping @MainActor @Sendable (TextTarget?) -> Void
) {
  guard identity.pid != getpid(), app.bundleIdentifier == "com.google.Chrome", AXIsProcessTrusted(),
    !app.isTerminated
  else {
    completion(nil)
    return
  }
  textQueue.async {
    let focusGate = WindowFocusGate()
    let result: TextTarget?
    if gate.isActive(),
      let (axApp, window) = matchingWindow(
        identity, gate: focusGate, bundleID: "com.google.Chrome"),
      let (target, title) = textTarget(axApp, window: window, gate: gate),
      textAttribute(axApp, kAXFocusedWindowAttribute).map({ CFEqual($0, window) }) == true,
      AXUIElementSetMessagingTimeout(target, 0.3) == .success
    {
      result = TextTarget(element: target, title: title)
    } else {
      result = nil
    }
    DispatchQueue.main.async {
      guard gate.isActive(), !app.isTerminated,
        NSRunningApplication(processIdentifier: identity.pid) == app
      else {
        completion(nil)
        return
      }
      completion(result)
    }
  }
}

@MainActor
func sendText(
  identity: WindowFocusIdentity, app: NSRunningApplication, gate: WindowTextGate,
  expected: TextTarget, text: String, completion: @escaping @MainActor @Sendable (String) -> Void
) {
  guard identity.pid != getpid(), app.bundleIdentifier == "com.google.Chrome", AXIsProcessTrusted(),
    !app.isTerminated, !text.isEmpty, text.utf8.count <= 65536
  else {
    completion("Text unavailable or too long.")
    return
  }
  textQueue.async {
    let focusGate = WindowFocusGate()
    guard gate.isActive(),
      let (axApp, window) = matchingWindow(
        identity, gate: focusGate, bundleID: "com.google.Chrome"),
      textAttribute(axApp, kAXFocusedWindowAttribute).map({ CFEqual($0, window) }) == true,
      let (target, _) = textTarget(axApp, window: window, gate: gate),
      CFEqual(target, expected.element),
      DispatchQueue.main.sync(execute: {
        NSApp.isActive && !app.isTerminated
          && NSRunningApplication(processIdentifier: identity.pid) == app
      })
    else {
      DispatchQueue.main.async { completion("Target changed or cannot be verified.") }
      return
    }
    let result = gate.commit {
      AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, text as CFTypeRef)
    }
    let readback = result == .success ? textAttribute(target, kAXValueAttribute) as? String : nil
    let message =
      result == .success && readback == text
      ? "Text read back from Accessibility; page behavior is not verified."
      : "Could not confirm text. The field may have changed."
    DispatchQueue.main.async { completion(message) }
  }
}
