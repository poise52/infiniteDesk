import AppKit
@preconcurrency import ApplicationServices
import Foundation

// The lock protects cancellation and the single mutation claim, never AX IPC.
final class WindowTextGate: @unchecked Sendable {
  private enum State { case pending, submitted, cancelled }
  private let lock = NSLock()
  private var state = State.pending
  private let deadline = DispatchTime.now() + .seconds(3)
  func isActive() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return state == .pending && DispatchTime.now() < deadline
  }
  func canObserve() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return state != .cancelled && DispatchTime.now() < deadline
  }
  func cancel() {
    lock.lock()
    state = .cancelled
    lock.unlock()
  }
  func commit(_ action: () -> AXError) -> AXError? {
    lock.lock()
    let claimed = state == .pending && DispatchTime.now() < deadline
    if claimed { state = .submitted }
    lock.unlock()
    guard claimed else { return nil }
    return action()
  }
}

enum TextReadbackSample: Equatable, Sendable {
  case value(String?)
  case contextChanged
}

enum TextReplacementResult: Equatable, Sendable {
  case cancelled
  case rejected(AXError)
  case ambiguous(AXError)
  case confirmed
  case unconfirmed
  case contextChanged

  var message: String {
    switch self {
    case .cancelled:
      "Text replacement cancelled before it was sent."
    case .rejected(let error):
      "Accessibility write failed (AX error \(error.rawValue)). Check the page before retrying."
    case .ambiguous(let error):
      "Accessibility delivery is uncertain (AX error \(error.rawValue)). Check the page before retrying."
    case .confirmed:
      "Text read back from Accessibility; page behavior is not verified."
    case .unconfirmed:
      "Write accepted; Accessibility has not confirmed the value. Check the page before retrying."
    case .contextChanged:
      "Write accepted; the target could not be revalidated. Check the page before retrying."
    }
  }
}

func submitTextReplacement(
  on queue: DispatchQueue, text: String,
  attempts: Int = 4, retryDelay: DispatchTimeInterval = .milliseconds(75),
  deadline: DispatchTime = .now() + .seconds(2),
  write: @Sendable () -> AXError?,
  read: @escaping @Sendable () -> TextReadbackSample,
  completion: @escaping @Sendable (TextReplacementResult) -> Void
) {
  dispatchPrecondition(condition: .onQueue(queue))
  guard let result = write() else {
    completion(.cancelled)
    return
  }
  guard result == .success || result == .cannotComplete else {
    completion(.rejected(result))
    return
  }
  confirmTextReplacement(
    on: queue, text: text, attempts: attempts, retryDelay: retryDelay, deadline: deadline,
    read: read,
    completion: { observation in
      completion(
        result == .cannotComplete && observation != .confirmed ? .ambiguous(result) : observation)
    })
}

private func confirmTextReplacement(
  on queue: DispatchQueue, text: String, attempts: Int,
  retryDelay: DispatchTimeInterval, deadline: DispatchTime,
  read: @escaping @Sendable () -> TextReadbackSample,
  completion: @escaping @Sendable (TextReplacementResult) -> Void
) {
  dispatchPrecondition(condition: .onQueue(queue))
  guard attempts > 0, DispatchTime.now() < deadline else {
    completion(.unconfirmed)
    return
  }
  switch read() {
  case .contextChanged:
    completion(.contextChanged)
  case .value(let value) where value == text:
    completion(.confirmed)
  case .value:
    guard attempts > 1, DispatchTime.now() < deadline else {
      completion(.unconfirmed)
      return
    }
    queue.asyncAfter(deadline: .now() + retryDelay) {
      confirmTextReplacement(
        on: queue, text: text, attempts: attempts - 1, retryDelay: retryDelay,
        deadline: deadline, read: read, completion: completion)
    }
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
  guard gate.canObserve(), let raw = textAttribute(app, kAXFocusedUIElementAttribute),
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
    guard gate.canObserve(), AXUIElementSetMessagingTimeout(current, 0.3) == .success else {
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

// Immutable references are used only on the serial AX queue.
private struct TextWindowContext: @unchecked Sendable {
  let application: AXUIElement
  let window: AXUIElement
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
    let context = TextWindowContext(application: axApp, window: window)
    submitTextReplacement(
      on: textQueue, text: text,
      write: {
        gate.commit {
          AXUIElementSetAttributeValue(
            expected.element, kAXValueAttribute as CFString, text as CFTypeRef)
        }
      },
      read: {
        var pid: pid_t = 0
        guard gate.canObserve(), AXIsProcessTrusted(),
          DispatchQueue.main.sync(execute: {
            NSApp.isActive && !app.isTerminated
              && NSRunningApplication(processIdentifier: identity.pid) == app
          }),
          AXUIElementGetPid(context.window, &pid) == .success, pid == identity.pid,
          textAttribute(context.application, kAXFocusedWindowAttribute).map({
            CFEqual($0, context.window)
          })
            == true,
          let (currentTarget, _) = textTarget(
            context.application, window: context.window, gate: gate),
          CFEqual(currentTarget, expected.element), gate.canObserve()
        else { return .contextChanged }
        let value = textAttribute(currentTarget, kAXValueAttribute) as? String
        return gate.canObserve() ? .value(value) : .contextChanged
      },
      completion: { result in
        DispatchQueue.main.async { completion(result.message) }
      })
  }
}
