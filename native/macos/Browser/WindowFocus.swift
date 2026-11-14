import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

struct WindowFocusIdentity: Equatable, Sendable {
  let windowID: CGWindowID
  let pid: pid_t
}

// The lock protects only cancellation state; it is never held across AX calls.
final class WindowFocusGate: @unchecked Sendable {
  private let lock = NSLock()
  private var active = true
  private let deadline = DispatchTime.now() + .seconds(3)
  func isActive() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return active && DispatchTime.now() < deadline
  }
  func finish() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard active else { return false }
    active = false
    return true
  }
  func cancel() { _ = finish() }
}

struct FocusGeometry: Equatable {
  let id: CGWindowID
  let rect: CGRect
  let title: String?
}

func uniqueFocusMatch(target: CGWindowID, cg: [FocusGeometry], ax: [CGRect]) -> Int? {
  guard let selected = cg.first(where: { $0.id == target }) else { return nil }
  func same(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5
      && abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
  }
  let cgMatches = cg.filter { same($0.rect, selected.rect) }
  let axMatches = ax.indices.filter { same(ax[$0], selected.rect) }
  guard cgMatches.count == 1, axMatches.count == 1 else { return nil }
  return axMatches[0]
}

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
    return nil
  }
  return value
}

private func axRect(_ element: AXUIElement, gate: WindowFocusGate) -> CGRect? {
  guard gate.isActive(), let position = attribute(element, kAXPositionAttribute),
    gate.isActive(), let size = attribute(element, kAXSizeAttribute),
    CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
  else { return nil }
  var p = CGPoint.zero
  var s = CGSize.zero
  guard AXValueGetValue(position as! AXValue, .cgPoint, &p),
    AXValueGetValue(size as! AXValue, .cgSize, &s),
    [p.x, p.y, s.width, s.height].allSatisfy(\.isFinite), s.width > 0, s.height > 0
  else { return nil }
  return CGRect(origin: p, size: s)
}

private func cgWindows(pid: pid_t) -> [FocusGeometry]? {
  guard let entries = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
  else {
    return nil
  }
  var result: [FocusGeometry] = []
  for entry in entries {
    guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
      (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
    else { continue }
    guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
      let bounds = entry[kCGWindowBounds as String] as? [String: Any],
      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
      [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
      rect.width > 0, rect.height > 0
    else { return nil }
    let title = entry[kCGWindowName as String] as? String
    result.append(FocusGeometry(id: id, rect: rect, title: title))
  }
  return result
}

private func matchingWindow(
  _ identity: WindowFocusIdentity, gate: WindowFocusGate, bundleID: String?
) -> (AXUIElement, AXUIElement)? {
  let app = AXUIElementCreateApplication(identity.pid)
  guard AXUIElementSetMessagingTimeout(app, 0.3) == .success,
    gate.isActive(), let value = attribute(app, kAXWindowsAttribute),
    let windows = value as? [AXUIElement],
    windows.count <= 80, gate.isActive(), let cg = cgWindows(pid: identity.pid)
  else { return nil }
  var rects: [CGRect] = []
  for window in windows {
    guard gate.isActive(), AXUIElementSetMessagingTimeout(window, 0.3) == .success,
      let rect = axRect(window, gate: gate)
    else {
      return nil
    }
    rects.append(rect)
  }
  guard let index = uniqueFocusMatch(target: identity.windowID, cg: cg, ax: rects),
    let selected = cg.first(where: { $0.id == identity.windowID })
  else { return nil }
  if let title = selected.title, !title.isEmpty {
    guard gate.isActive(), let axTitle = attribute(windows[index], kAXTitleAttribute) as? String,
      focusTitlesMatch(cg: title, ax: axTitle, bundleID: bundleID)
    else {
      return nil
    }
  }
  return (app, windows[index])
}

func focusTitlesMatch(cg: String, ax: String, bundleID: String?) -> Bool {
  cg == ax || (bundleID == "com.google.Chrome" && ax == cg + " - Google Chrome")
}

private let focusQueue = DispatchQueue(label: "dev.infinitedesk.window-focus", qos: .userInitiated)

@MainActor
func requestWindowFocus(
  identity: WindowFocusIdentity, app: NSRunningApplication, gate: WindowFocusGate,
  completion: @escaping @MainActor @Sendable (String) -> Void
) {
  guard identity.pid != getpid() else {
    gate.cancel()
    completion("Cannot focus a window in InfiniteDesk itself.")
    return
  }
  guard AXIsProcessTrusted() else {
    let options =
      [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    gate.cancel()
    completion("Allow Accessibility access, then try again.")
    return
  }
  DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
    if gate.finish() { completion("Window focus timed out.") }
  }
  let bundleID = app.bundleIdentifier
  focusQueue.async {
    guard gate.isActive(),
      let (_, window) = matchingWindow(identity, gate: gate, bundleID: bundleID)
    else {
      DispatchQueue.main.async {
        if gate.finish() { completion("Cannot uniquely identify this window.") }
      }
      return
    }
    let activated = DispatchQueue.main.sync {
      guard gate.isActive(), !app.isTerminated,
        NSRunningApplication(processIdentifier: identity.pid) == app
      else { return false }
      return app.activate()
    }
    guard activated, gate.isActive(),
      let (currentApp, currentWindow) = matchingWindow(identity, gate: gate, bundleID: bundleID),
      CFEqual(window, currentWindow), gate.isActive()
    else {
      DispatchQueue.main.async {
        if gate.finish() { completion("Window changed or could not be activated.") }
      }
      return
    }
    let raised = AXUIElementPerformAction(currentWindow, kAXRaiseAction as CFString) == .success
    var confirmed = false
    if raised {
      for _ in 0..<10 {
        guard gate.isActive() else { return }
        if let focused = attribute(currentApp, kAXFocusedWindowAttribute),
          CFEqual(focused, currentWindow)
        {
          confirmed = true
          break
        }
        Thread.sleep(forTimeInterval: 0.05)
      }
    }
    DispatchQueue.main.async {
      guard gate.finish() else { return }
      if confirmed && NSWorkspace.shared.frontmostApplication == app {
        completion("Selected window focused.")
      } else {
        completion("Could not confirm focus on the selected window.")
      }
    }
  }
}

#if FOCUS_TESTING
  func testFocusedWindow(_ identity: WindowFocusIdentity, bundleID: String?) -> Bool? {
    guard identity.pid != getpid() else { return nil }
    let gate = WindowFocusGate()
    guard let (app, window) = matchingWindow(identity, gate: gate, bundleID: bundleID),
      let focused = attribute(app, kAXFocusedWindowAttribute)
    else { return nil }
    return CFEqual(window, focused)
  }
#endif
