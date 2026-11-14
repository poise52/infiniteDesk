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

func textPointInWindow(normalized: CGPoint, sourceSize: CGSize, window: CGRect) -> CGPoint? {
  guard
    [
      normalized.x, normalized.y, sourceSize.width, sourceSize.height,
      window.minX, window.minY, window.width, window.height,
    ].allSatisfy(\.isFinite),
    normalized.x >= 0, normalized.x < 1, normalized.y >= 0, normalized.y < 1,
    sourceSize.width > 0, sourceSize.height > 0, window.width > 0, window.height > 0,
    abs(sourceSize.width - window.width) <= 0.5,
    abs(sourceSize.height - window.height) <= 0.5
  else { return nil }
  return CGPoint(
    x: window.minX + normalized.x * window.width,
    y: window.minY + normalized.y * window.height)
}

func sameTextGeometry(_ first: CGRect, _ second: CGRect) -> Bool {
  abs(first.minX - second.minX) <= 0.5 && abs(first.minY - second.minY) <= 0.5
    && abs(first.width - second.width) <= 0.5 && abs(first.height - second.height) <= 0.5
}

private struct TextPointRequest: Sendable {
  let normalized: CGPoint
  let sourceSize: CGSize
}

private enum TextTargetFailure: Error {
  case unavailable, windowChanged, noEditableField

  var message: String {
    switch self {
    case .unavailable: "Chrome Accessibility is unavailable."
    case .windowChanged: "Selected window or preview geometry changed. Select the field again."
    case .noEditableField: "No unambiguous editable page field at this point."
    }
  }
}

private struct ResolvedTextTarget {
  let element: AXUIElement
  let title: String
  let relativeFrame: CGRect
}

private func validateTextElement(
  _ element: AXUIElement, window: AXUIElement, gate: WindowTextGate,
  pid: pid_t, point: CGPoint?
) -> ResolvedTextTarget? {
  var elementPID: pid_t = 0
  guard gate.canObserve(), AXUIElementSetMessagingTimeout(element, 0.3) == .success,
    AXUIElementGetPid(element, &elementPID) == .success, elementPID == pid,
    let role = textAttribute(element, kAXRoleAttribute) as? String
  else { return nil }
  var subroleValue: CFTypeRef?
  let subroleResult = AXUIElementCopyAttributeValue(
    element, kAXSubroleAttribute as CFString, &subroleValue)
  guard
    subroleResult == .success || subroleResult == .attributeUnsupported
      || subroleResult == .noValue,
    subroleResult != .success || subroleValue is String,
    isAllowedTextRole(role, subrole: subroleValue as? String, inWebArea: true)
  else { return nil }
  var settable = DarwinBoolean(false)
  guard
    AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
    settable.boolValue,
    (textAttribute(element, kAXEnabledAttribute) as? Bool) == true
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
  guard reachedWindow,
    isAllowedTextRole(role, subrole: subroleValue as? String, inWebArea: inWebArea),
    let rect = textRect(element), let windowRect = textRect(window),
    !rect.intersection(windowRect).isNull, !rect.intersection(windowRect).isEmpty,
    point.map({ rect.contains($0) && windowRect.contains($0) }) ?? true
  else { return nil }
  let title =
    (textAttribute(element, kAXTitleAttribute) as? String)
    ?? (textAttribute(element, kAXDescriptionAttribute) as? String) ?? "Unnamed field"
  return ResolvedTextTarget(
    element: element, title: String(title.prefix(120)),
    relativeFrame: rect.offsetBy(dx: -windowRect.minX, dy: -windowRect.minY))
}

private func textTarget(
  _ app: AXUIElement, window: AXUIElement, pid: pid_t, gate: WindowTextGate,
  pointRequest: TextPointRequest?
) -> Result<ResolvedTextTarget, TextTargetFailure> {
  guard gate.canObserve() else { return .failure(.unavailable) }
  let element: AXUIElement
  let point: CGPoint?
  if let pointRequest {
    guard let windowFrame = textRect(window),
      let mapped = textPointInWindow(
        normalized: pointRequest.normalized, sourceSize: pointRequest.sourceSize,
        window: windowFrame)
    else { return .failure(.windowChanged) }
    point = mapped
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(app, Float(mapped.x), Float(mapped.y), &hit) == .success,
      let hit
    else { return .failure(.noEditableField) }
    guard let hitWindow = textAttribute(hit, kAXWindowAttribute),
      CFGetTypeID(hitWindow) == AXUIElementGetTypeID(), CFEqual(hitWindow, window)
    else { return .failure(.windowChanged) }
    element = hit
  } else {
    guard textAttribute(app, kAXFocusedWindowAttribute).map({ CFEqual($0, window) }) == true,
      let raw = textAttribute(app, kAXFocusedUIElementAttribute),
      CFGetTypeID(raw) == AXUIElementGetTypeID()
    else { return .failure(.windowChanged) }
    element = raw as! AXUIElement
    point = nil
  }
  guard
    let result = validateTextElement(element, window: window, gate: gate, pid: pid, point: point)
  else { return .failure(.noEditableField) }
  return .success(result)
}

// Immutable AX references are used only on the serial AX queue.
final class TextTarget: @unchecked Sendable {
  let element: AXUIElement
  let title: String
  fileprivate let window: AXUIElement
  fileprivate let relativeFrame: CGRect
  fileprivate let pointRequest: TextPointRequest?

  fileprivate init(
    resolved: ResolvedTextTarget, window: AXUIElement, pointRequest: TextPointRequest?
  ) {
    self.element = resolved.element
    self.title = resolved.title
    self.window = window
    self.relativeFrame = resolved.relativeFrame
    self.pointRequest = pointRequest
  }
}

func textAccessibilityAvailable() -> Bool { AXIsProcessTrusted() }

private let textQueue = DispatchQueue(label: "dev.infinitedesk.text-input", qos: .userInitiated)

@MainActor
func inspectTextTarget(
  identity: WindowFocusIdentity, app: NSRunningApplication, gate: WindowTextGate,
  point: CGPoint? = nil, sourceSize: CGSize? = nil,
  completion: @escaping @MainActor @Sendable (TextTarget?, String?) -> Void
) {
  guard identity.pid != getpid(), app.bundleIdentifier == "com.google.Chrome", AXIsProcessTrusted(),
    !app.isTerminated, (point == nil) == (sourceSize == nil)
  else {
    completion(nil, TextTargetFailure.unavailable.message)
    return
  }
  let pointRequest = point.flatMap { normalized in
    sourceSize.map { TextPointRequest(normalized: normalized, sourceSize: $0) }
  }
  textQueue.async {
    let result: TextTarget?
    let failure: String?
    if gate.isActive(),
      let (axApp, window) = matchingWindow(
        identity, gate: WindowFocusGate(), bundleID: "com.google.Chrome")
    {
      switch textTarget(
        axApp, window: window, pid: identity.pid, gate: gate, pointRequest: pointRequest)
      {
      case .success(let resolved):
        result = TextTarget(resolved: resolved, window: window, pointRequest: pointRequest)
        failure = nil
      case .failure(let error):
        result = nil
        failure = error.message
      }
    } else {
      result = nil
      failure = TextTargetFailure.windowChanged.message
    }
    DispatchQueue.main.async {
      guard gate.isActive(), !app.isTerminated,
        NSRunningApplication(processIdentifier: identity.pid) == app
      else {
        completion(nil, TextTargetFailure.unavailable.message)
        return
      }
      completion(result, failure)
    }
  }
}

private func revalidateTextTarget(
  identity: WindowFocusIdentity, expected: TextTarget, gate: WindowTextGate
) -> AXUIElement? {
  guard gate.canObserve(), AXIsProcessTrusted(),
    let (axApp, window) = matchingWindow(
      identity, gate: WindowFocusGate(), bundleID: "com.google.Chrome"),
    CFEqual(window, expected.window),
    case .success(let resolved) = textTarget(
      axApp, window: window, pid: identity.pid, gate: gate, pointRequest: expected.pointRequest),
    CFEqual(resolved.element, expected.element),
    expected.pointRequest == nil
      || sameTextGeometry(resolved.relativeFrame, expected.relativeFrame),
    gate.canObserve()
  else { return nil }
  return resolved.element
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
    @Sendable func applicationIsCurrent() -> Bool {
      DispatchQueue.main.sync {
        NSApp.isActive && !app.isTerminated
          && NSRunningApplication(processIdentifier: identity.pid) == app
      }
    }
    guard gate.isActive(),
      revalidateTextTarget(identity: identity, expected: expected, gate: gate) != nil
    else {
      DispatchQueue.main.async { completion("Target changed or cannot be verified.") }
      return
    }
    submitTextReplacement(
      on: textQueue, text: text,
      write: {
        guard applicationIsCurrent() else { return nil }
        return gate.commit {
          AXUIElementSetAttributeValue(
            expected.element, kAXValueAttribute as CFString, text as CFTypeRef)
        }
      },
      read: {
        guard applicationIsCurrent(),
          let target = revalidateTextTarget(identity: identity, expected: expected, gate: gate)
        else { return .contextChanged }
        let value = textAttribute(target, kAXValueAttribute) as? String
        return gate.canObserve() ? .value(value) : .contextChanged
      },
      completion: { result in
        DispatchQueue.main.async { completion(result.message) }
      })
  }
}
