import AppKit
@preconcurrency import ApplicationServices
import Foundation

enum BrowserDelivery: Sendable { case ax, pointer }

func browserPress(
  pid: pid_t, windowID: CGWindowID, title: String, frame: CGRect, point: CGPoint,
  token: FocusCancellation, delivery: BrowserDelivery
) -> String {
  func currentWindowMatches() -> Bool {
    guard
      let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
      rows.count == 1, let row = rows.first,
      (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID,
      (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
      let bounds = row[kCGWindowBounds as String] as? [String: Any],
      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
    else { return false }
    return abs(rect.minX - frame.minX) < 2 && abs(rect.minY - frame.minY) < 2
      && abs(rect.width - frame.width) < 2 && abs(rect.height - frame.height) < 2
  }
  func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
  }
  guard currentWindowMatches(), !token.isCancelled() else {
    return "CG window identity or geometry changed"
  }
  let app = AXUIElementCreateApplication(pid)
  guard AXUIElementSetMessagingTimeout(app, 0.15) == .success, !token.isCancelled(),
    let windows = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement]
  else { return "AX windows unavailable" }
  let titles = windows.map { attribute($0, kAXTitleAttribute as CFString) as? String }
  let candidates = windows.indices.filter { browserTitleCount(titles[$0], expected: title) != nil }
  guard candidates.count == 1 else {
    return "AX windows=\(windows.count), matching titles=\(candidates.count)"
  }
  let window = windows[candidates[0]]
  var position: CFTypeRef?
  var size: CFTypeRef?
  let positionError = AXUIElementCopyAttributeValue(
    window, kAXPositionAttribute as CFString, &position)
  let sizeError = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size)
  guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
    CFGetTypeID(size) == AXValueGetTypeID()
  else { return "AX position=\(positionError.rawValue), size=\(sizeError.rawValue)" }
  func rect(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute as CFString),
      let size = attribute(element, kAXSizeAttribute as CFString),
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
      AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
    else { return nil }
    return CGRect(origin: origin, size: dimensions)
  }
  func windowMatches() -> Bool {
    guard let actual = rect(window), actual.contains(point) else { return false }
    return abs(actual.minX - frame.minX) < 2 && abs(actual.minY - frame.minY) < 2
      && abs(actual.width - frame.width) < 2 && abs(actual.height - frame.height) < 2
  }
  func readCount() -> UInt64? {
    var windowPID: pid_t = 0
    guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == pid,
      !token.isCancelled(), currentWindowMatches(), windowMatches(),
      let currentWindows = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement]
    else { return nil }
    let matches = currentWindows.filter {
      browserTitleCount(attribute($0, kAXTitleAttribute as CFString) as? String, expected: title)
        != nil
    }
    guard matches.count == 1, CFEqual(matches[0], window),
      let count = browserTitleCount(
        attribute(window, kAXTitleAttribute as CFString) as? String, expected: title),
      !token.isCancelled()
    else { return nil }
    return count
  }
  guard windowMatches(), let baseline = readCount() else {
    return "AX/SCK identity or geometry changed"
  }
  var hit: AXUIElement?
  let hitError = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
  guard hitError == .success, let hit else { return "AX hit test: \(hitError.rawValue)" }
  var candidate = hit
  for depth in 0...3 {
    var owner: pid_t = 0
    let role = attribute(candidate, kAXRoleAttribute as CFString) as? String
    let hitTitle = attribute(candidate, kAXTitleAttribute as CFString) as? String
    guard AXUIElementGetPid(candidate, &owner) == .success, owner == pid,
      let hitWindow = attribute(candidate, kAXWindowAttribute as CFString),
      CFGetTypeID(hitWindow) == AXUIElementGetTypeID(), CFEqual(hitWindow, window),
      let top = attribute(candidate, kAXTopLevelUIElementAttribute as CFString),
      CFEqual(top, window),
      !token.isCancelled()
    else { return "AX hit owner/window mismatch" }
    if role == (kAXButtonRole as String), hitTitle == "Press me" {
      guard let bounds = rect(candidate), bounds.contains(point),
        let before = readCount(), before == baseline, !token.isCancelled()
      else {
        return "AX button bounds or baseline changed"
      }
      let sent: String
      switch delivery {
      case .ax:
        let result = AXUIElementPerformAction(candidate, kAXPressAction as CFString)
        guard result == .success else { return "AXPress: \(result.rawValue)" }
        sent = "AXPress accepted"
      case .pointer:
        guard CGPreflightPostEventAccess(),
          let down = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left),
          !token.isCancelled(), currentWindowMatches(), !token.isCancelled()
        else { return "Pointer blocked: permission, event creation or identity" }
        for event in [down, up] {
          event.setIntegerValueField(.mouseEventNumber, value: 1)
          event.setIntegerValueField(.mouseEventClickState, value: 1)
          event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
          event.setIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        }
        down.postToPid(pid)
        up.postToPid(pid)
        sent = "Pointer down/up posted"
      }
      let deadline = ProcessInfo.processInfo.systemUptime + 1.0
      repeat {
        guard !token.isCancelled() else { return "\(sent), acknowledgement cancelled" }
        if let count = readCount(), count > baseline {
          return "\(sent); DOM acknowledged Pressed \(count) (baseline \(baseline))"
        }
        Thread.sleep(forTimeInterval: 0.05)
      } while ProcessInfo.processInfo.systemUptime < deadline
      return "\(sent), no DOM acknowledgement (baseline \(baseline))"
    }
    guard depth < 3,
      role == (kAXStaticTextRole as String) || (depth > 0 && role == (kAXGroupRole as String)),
      let parent = attribute(candidate, kAXParentAttribute as CFString),
      CFGetTypeID(parent) == AXUIElementGetTypeID()
    else {
      return
        "AX hit pid=\(owner), role=\(role ?? "nil"), title=\(hitTitle ?? "nil"); no matching button"
    }
    candidate = parent as! AXUIElement
  }
  return "AX button unavailable"

}

@MainActor extension ProbeDelegate {
  @objc func toggleBrowserDelivery(_ sender: NSButton) {
    releaseInput()
    inputEnabled = false
    browserDelivery = browserDelivery == .ax ? .pointer : .ax
    sender.title = browserDelivery == .ax ? "Browser AX" : "Browser Pointer"
    focusDiagnostic = "Browser mode: \(browserDelivery == .ax ? "AX" : "Pointer"); input OFF"
    updateGeometryStatus()
  }

  @objc func showBrowser() {
    guard let process = browser, validTarget(),
      let app = NSRunningApplication(processIdentifier: process.processIdentifier)
    else {
      focusDiagnostic = "Browser source unavailable"
      updateGeometryStatus()
      return
    }
    releaseInput()
    inputEnabled = false
    if !app.activate() {
      focusDiagnostic = "Browser activation was not accepted"
      updateGeometryStatus()
    }
  }

  @objc func launchBrowser() {
    guard fixture?.isRunning != true, browser?.isRunning != true, !session.busy,
      !stopping, unknownStream == nil
    else {
      status.stringValue = "Stop capture and close the existing target before launching browser"
      return
    }
    let executable = URL(
      fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      status.stringValue = "Google Chrome is not installed at /Applications/Google Chrome.app"
      return
    }
    fixture = nil
    handshake = nil
    browser = nil
    browserTitle = nil
    let title = "InfiniteDesk-" + UUID().uuidString
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      title, isDirectory: true)
    var created = false
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
      created = true
      let page = dir.appendingPathComponent("index.html")
      guard let templateURL = Bundle.main.url(forResource: "BrowserFixture", withExtension: "html")
      else {
        throw CocoaError(.fileNoSuchFile)
      }
      let template = try String(contentsOf: templateURL, encoding: .utf8)
      let html = template.replacingOccurrences(of: "__STAGE6_NONCE__", with: title)
      try html.write(to: page, atomically: true, encoding: .utf8)
      let process = Process()
      process.executableURL = executable
      process.arguments = [
        "--user-data-dir=\(dir.appendingPathComponent("profile").path)",
        "--no-first-run", "--no-default-browser-check", "--new-window", page.absoluteString,
      ]
      process.terminationHandler = { _ in try? FileManager.default.removeItem(at: dir) }
      try process.run()
      browser = process
      browserTitle = title
      fixtureGeneration += 1
      status.stringValue =
        "Browser PID \(process.processIdentifier), title \(title). Wait for page, then Start capture."
    } catch {
      if created { try? FileManager.default.removeItem(at: dir) }
      status.stringValue = "Browser launch failed: \(error)"
    }
  }

  func pressBrowser(_ point: CGPoint) {
    guard let process = browser, let title = browserTitle, let target = targetWindow,
      validTarget(), inputEnabled, session.busy, stream != nil, canvas.image != nil,
      probeHasFocus(),
      AXIsProcessTrusted(), browserDelivery == .ax || CGPreflightPostEventAccess(),
      !browserPressPending,
      streamActivityFresh(last: lastStreamActivity, now: ProcessInfo.processInfo.systemUptime)
    else {
      focusDiagnostic = "Browser press unavailable"
      updateGeometryStatus()
      return
    }
    let frame = canvas.sourceRect
    let generation = session.generation
    let windowID = target.windowID
    let token = FocusCancellation()
    browserPressToken = token
    browserPressPending = true
    let started = ProcessInfo.processInfo.systemUptime
    let pid = process.processIdentifier
    let delivery = browserDelivery
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { token.cancel() }
    axQueue.async { [weak self] in
      let result = browserPress(
        pid: pid, windowID: windowID, title: title, frame: frame, point: point, token: token,
        delivery: delivery)
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard self.browserPressToken === token else { return }
        self.browserPressPending = false
        self.browserPressToken = nil
        guard self.session.isCurrent(generation), self.targetWindow?.windowID == windowID
        else { return }
        self.focusDiagnostic =
          "Browser \(delivery == .ax ? "AX" : "Pointer"): \(result) (\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms)"
        self.updateGeometryStatus()
      }
    }
  }
}
