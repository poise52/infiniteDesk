import AppKit
@preconcurrency import ApplicationServices
import Foundation

func browserPress(
  pid: pid_t, windowID: CGWindowID, title: String, frame: CGRect, point: CGPoint,
  token: FocusCancellation
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
      let result = AXUIElementPerformAction(candidate, kAXPressAction as CFString)
      guard result == .success else { return "AXPress: \(result.rawValue)" }
      let deadline = ProcessInfo.processInfo.systemUptime + 1.0
      repeat {
        guard !token.isCancelled() else { return "AXPress accepted, acknowledgement cancelled" }
        if let count = readCount(), count > baseline {
          return "DOM acknowledged Pressed \(count) (baseline \(baseline))"
        }
        Thread.sleep(forTimeInterval: 0.05)
      } while ProcessInfo.processInfo.systemUptime < deadline
      return "AXPress accepted, no DOM acknowledgement (baseline \(baseline))"
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
      let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body data-count="0" style="font: 24px system-ui; padding: 32px">
        <h1>InfiniteDesk browser test</h1><p>\(title)</p>
        <button style="font: inherit; padding: 16px" onclick="const n = Number(document.body.dataset.count) + 1; document.body.dataset.count = String(n); document.getElementById('result').textContent = 'Pressed ' + n; document.title = '\(title) · Pressed ' + n">Press me</button>
        <p id="result">Not pressed</p><label>Test field <input style="font: inherit"></label>
        </body></html>
        """
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
      AXIsProcessTrusted(), !browserPressPending,
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
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { token.cancel() }
    axQueue.async { [weak self] in
      let result = browserPress(
        pid: pid, windowID: windowID, title: title, frame: frame, point: point, token: token)
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard self.browserPressToken === token else { return }
        self.browserPressPending = false
        self.browserPressToken = nil
        guard self.session.isCurrent(generation), self.targetWindow?.windowID == windowID
        else { return }
        self.focusDiagnostic =
          "Browser: \(result) (\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms)"
        self.updateGeometryStatus()
      }
    }
  }
}
