import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct GestureGuardSample: Sendable {
  let elapsedMS: Int
  let hidFlags: UInt64
  let combinedFlags: UInt64
  let hidLeftButton: Bool
  let combinedLeftButton: Bool
  let frontmostPID: pid_t

  var json: [String: Any] {
    ["elapsedMS": elapsedMS, "hidFlags": hidFlags, "hidFlagsHex": String(hidFlags, radix: 16),
     "combinedFlags": combinedFlags, "combinedFlagsHex": String(combinedFlags, radix: 16),
     "hidLeftButton": hidLeftButton, "combinedLeftButton": combinedLeftButton,
     "frontmostPID": frontmostPID]
  }
}

enum Failure: Error {
  case message(String)
  case gesturePrecondition([GestureGuardSample])
  case gestureHit([GestureHitSample])
}

func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
  var result: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else {
    return nil
  }
  return result
}

func rectangle(_ element: AXUIElement) -> CGRect? {
  guard let position = attribute(element, kAXPositionAttribute),
    let size = attribute(element, kAXSizeAttribute),
    CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
  else { return nil }
  var point = CGPoint.zero
  var dimensions = CGSize.zero
  guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
    AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
  else { return nil }
  return CGRect(origin: point, size: dimensions)
}

func equal(_ a: CGRect, _ b: CGRect) -> Bool {
  abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
    && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
}

func frameJSON(_ frame: CGRect) -> [String: Double] {
  ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
}

func visibleFrames(_ pid: pid_t) throws -> [CGWindowID: CGRect] {
  guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
    throw Failure.message("Cannot read visible windows")
  }
  var frames: [CGWindowID: CGRect] = [:]
  for entry in list {
    guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
      (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
      let number = entry[kCGWindowNumber as String] as? NSNumber,
      let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
      let frame = CGRect(dictionaryRepresentation: bounds)
    else { continue }
    frames[number.uint32Value] = frame
  }
  return frames
}

struct Window {
  let id: CGWindowID
  let element: AXUIElement
  let frame: CGRect
  let title: String
}

func finderSnapshot() throws -> [[String: Any]] {
  let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").map(\.processIdentifier))
  guard let entries = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
    throw Failure.message("Cannot read visible Finder window geometry")
  }
  return entries.compactMap { entry in
    guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
      pids.contains(pid), (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
      let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
      let bounds = entry[kCGWindowBounds as String] as? [String: Any],
      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.width >= 80, frame.height >= 60
    else { return nil }
    return ["pid": pid, "id": id, "frame": frameJSON(frame)]
  }
}

struct CGHit: Sendable {
  let pid: pid_t
  let id: CGWindowID
  let layer: Int
  var json: [String: Any] { ["pid": pid, "id": id, "layer": layer] }
}

struct GestureHitSample: Sendable {
  let point: CGPoint
  let top: CGHit?
  let normal: CGHit?
  let axPID: pid_t
  let axRole: String
  let exactAXWindow: Bool

  func matches(_ target: Window, pid: pid_t) -> Bool {
    axPID == pid && exactAXWindow && normal?.pid == pid && normal?.id == target.id
  }
  var json: [String: Any] {
    ["point": ["x": point.x, "y": point.y], "topCG": top?.json ?? [:],
     "firstLayer0CG": normal?.json ?? [:], "axPID": axPID, "axRole": axRole,
     "exactRetainedAXWindow": exactAXWindow]
  }
}

func gestureHit(at point: CGPoint, target: AXUIElement) -> GestureHitSample {
  let entries = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
  var top: CGHit?
  var normal: CGHit?
  for entry in entries {
    guard (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
      let bounds = entry[kCGWindowBounds as String] as? [String: Any],
      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(point),
      let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
      let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
      let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue
    else { continue }
    let hit = CGHit(pid: pid, id: id, layer: layer)
    if top == nil { top = hit }
    if layer == 0 { normal = hit; break }
  }
  var element: AXUIElement?
  var owner: pid_t = 0
  var role = "unavailable"
  var exact = false
  guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
    let hit = element
  else { return GestureHitSample(point: point, top: top, normal: normal, axPID: owner, axRole: role, exactAXWindow: false) }
  _ = AXUIElementGetPid(hit, &owner)
  role = attribute(hit, kAXRoleAttribute) as? String ?? "unavailable"
  var candidate: AXUIElement? = hit
  for _ in 0..<12 {
    guard let current = candidate else { break }
    if attribute(current, kAXRoleAttribute) as? String == kAXWindowRole {
      exact = CFEqual(current, target)
      break
    }
    if let window = attribute(current, kAXWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID(), CFEqual(window, target) {
      exact = true
      break
    }
    guard let parent = attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
    candidate = (parent as! AXUIElement)
  }
  return GestureHitSample(point: point, top: top, normal: normal, axPID: owner, axRole: role, exactAXWindow: exact)
}

func mouseGesture(_ target: Window, pid: pid_t, app: AXUIElement, payload: String) throws -> [String: Any] {
  guard let data = payload.data(using: .utf8),
    let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    let kind = request["kind"] as? String, ["click", "drag", "resize"].contains(kind),
    let expected = request["expectedFrame"] as? [String: Double],
    let x = expected["x"], let y = expected["y"], let width = expected["width"], let height = expected["height"],
    let dx = request["dx"] as? Double, let dy = request["dy"] as? Double,
    [x, y, width, height, dx, dy].allSatisfy(\.isFinite), abs(dx) <= 1000, abs(dy) <= 1000,
    equal(target.frame, CGRect(x: x, y: y, width: width, height: height)),
    let source = CGEventSource(stateID: .privateState)
  else { throw Failure.message("Invalid gesture or target frame changed before input") }
  let guardStarted = Date()
  let modifierMask: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
  var guardSamples: [GestureGuardSample] = []
  while true {
    let sample = GestureGuardSample(
      elapsedMS: Int(Date().timeIntervalSince(guardStarted) * 1000),
      hidFlags: CGEventSource.flagsState(.hidSystemState).rawValue,
      combinedFlags: CGEventSource.flagsState(.combinedSessionState).rawValue,
      hidLeftButton: CGEventSource.buttonState(.hidSystemState, button: .left),
      combinedLeftButton: CGEventSource.buttonState(.combinedSessionState, button: .left),
      frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
    guardSamples.append(sample)
    if sample.hidFlags & modifierMask.rawValue == 0, !sample.hidLeftButton, sample.frontmostPID == pid { break }
    guard sample.elapsedMS < 600 else { throw Failure.gesturePrecondition(guardSamples) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.025))
  }
  func focused() -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
      let value = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return false }
    return CFEqual(value, target.element) && rectangle(target.element) != nil
  }
  guard kind == "click" || focused() else { throw Failure.message("Gesture target must already have native focus") }
  let candidates: [CGPoint] = kind == "resize"
    ? [4.0, 6, 8].map { CGPoint(x: target.frame.maxX - $0, y: target.frame.maxY - $0) }
    : [110.0, 160, 210, 260, 310].map { CGPoint(x: target.frame.maxX - $0, y: target.frame.minY + 14) }
      .filter { $0.x >= target.frame.minX + 330 }
  var hitSamples: [GestureHitSample] = []
  var selectedPoint: CGPoint?
  for point in candidates {
    let hit = gestureHit(at: point, target: target.element)
    hitSamples.append(hit)
    if hit.matches(target, pid: pid) { selectedPoint = point; break }
  }
  guard let start = selectedPoint else { throw Failure.gestureHit(hitSamples) }
  let end = CGPoint(x: start.x + dx, y: start.y + dy)
  let safeBounds = CGDisplayBounds(CGMainDisplayID()).insetBy(dx: 16, dy: 32)
  guard safeBounds.contains(start), safeBounds.contains(end),
    kind != "click" || (dx == 0 && dy == 0)
  else { throw Failure.message("Gesture point is outside safe display bounds or covered by another native window") }
  let duration = (request["durationMS"] as? Double ?? 300) / 1000
  guard duration >= 0.1, duration <= 0.8 else { throw Failure.message("Gesture duration is outside safe bounds") }
  func send(_ type: CGEventType, _ point: CGPoint) throws {
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
      throw Failure.message("Cannot create mouse event")
    }
    event.flags = []
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
  }
  var held = false
  var last = start
  defer { if held { try? send(.leftMouseUp, last) } }
  try send(.mouseMoved, start)
  Thread.sleep(forTimeInterval: 0.025)
  let finalHit = gestureHit(at: start, target: target.element)
  hitSamples.append(finalHit)
  guard finalHit.matches(target, pid: pid) else { throw Failure.gestureHit(hitSamples) }
  try send(.leftMouseDown, start)
  held = true
  if kind == "click" {
    Thread.sleep(forTimeInterval: 0.05)
  } else {
    for step in 1...12 {
      guard focused() else { throw Failure.message("Gesture lost its retained AX target") }
      last = CGPoint(x: start.x + dx * Double(step) / 12, y: start.y + dy * Double(step) / 12)
      try send(.leftMouseDragged, last)
      Thread.sleep(forTimeInterval: duration / 12)
    }
  }
  try send(.leftMouseUp, end)
  held = false
  return ["status": "sent", "kind": kind, "pid": pid, "id": target.id,
          "from": ["x": start.x, "y": start.y], "to": ["x": end.x, "y": end.y],
          "durationMS": duration * 1000, "completedAt": Date().timeIntervalSince1970,
          "guardSamples": guardSamples.map(\.json), "hitSamples": hitSamples.map(\.json)]
}

func windows(_ pid: pid_t, app: AXUIElement) throws -> [Window] {
  guard let axWindows = attribute(app, kAXWindowsAttribute) as? [AXUIElement],
    let cgWindows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
  else { throw Failure.message("Cannot enumerate disposable Chrome windows") }
  var result: [Window] = []
  for element in axWindows {
    _ = AXUIElementSetMessagingTimeout(element, 0.3)
    guard let frame = rectangle(element) else { continue }
    let candidates = cgWindows.filter { entry in
      guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
        (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let bounds = entry[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
      else { return false }
      return equal(frame, rect)
    }
    guard candidates.count == 1,
      let id = (candidates[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value
    else { throw Failure.message("Native geometry is ambiguous; refusing to choose a window") }
    result.append(Window(id: id, element: element, frame: frame,
                         title: attribute(element, kAXTitleAttribute) as? String ?? ""))
  }
  return result
}

func focusedID(_ app: AXUIElement, windows: [Window]) -> CGWindowID? {
  guard let value = attribute(app, kAXFocusedWindowAttribute),
    CFGetTypeID(value) == AXUIElementGetTypeID()
  else { return nil }
  return windows.first { CFEqual($0.element, value) }?.id
}

func postKey(_ code: CGKeyCode, flags: CGEventFlags, pid: pid_t? = nil) throws {
  guard let source = CGEventSource(stateID: .privateState) else {
    throw Failure.message("Cannot create isolated key event source")
  }
  for down in [true, false] {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
      throw Failure.message("Cannot create key event")
    }
    let intrinsic = event.flags.intersection([.maskNumericPad, .maskSecondaryFn])
    event.flags = down ? flags.union(intrinsic) : intrinsic
    if let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
    Thread.sleep(forTimeInterval: 0.025)
  }
}

func output(_ value: [String: Any], exitCode: Int32 = 0) throws {
  let args = CommandLine.arguments
  guard args.count >= 4, args[1] == "--result", args[2].hasPrefix("/") else {
    throw Failure.message("Launch through driver-command.sh; missing absolute result path")
  }
  let envelope: [String: Any] = ["protocolVersion": 1, "exitCode": exitCode, "result": value]
  let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
  try data.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
}

func launchContext() -> [String: Any] {
  var lineage: [[String: Any]] = []
  var pid = getpid()
  for _ in 0..<12 {
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let pathLength = proc_pidpath(pid, &path, UInt32(path.count))
    var info = proc_bsdinfo()
    let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize)
    let executable = pathLength > 0 ? String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : "unavailable"
    lineage.append(["pid": pid, "executable": executable])
    guard count == infoSize, info.pbi_ppid > 0, info.pbi_ppid != UInt32(pid) else { break }
    pid = pid_t(info.pbi_ppid)
  }
  let environment = ProcessInfo.processInfo.environment
  return [
    "executable": URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path,
    "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unbundled",
    "ancestry": lineage,
    "terminalProgram": environment["TERM_PROGRAM"] ?? "unset",
    "launchBundleHint": environment["__CFBundleIdentifier"] ?? "unset",
    "launchRoute": "LaunchServices via driver-command.sh; permission identity is the dedicated acceptance app",
  ]
}

@MainActor func run() throws {
  guard CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--result",
    Bundle.main.bundleIdentifier == "org.infinitedesk.tests.desktop-acceptance"
  else { throw Failure.message("Expected dedicated acceptance bundle launched through driver-command.sh") }
  let args = Array(CommandLine.arguments.dropFirst(3))
  let trusted = AXIsProcessTrusted()
  let posting = CGPreflightPostEventAccess()
  guard trusted && posting else {
    try output(["status": "SKIP", "accessibility": trusted, "eventPosting": posting,
                "launchContext": launchContext(),
                "reason": "Acceptance app permissions are insufficient; no permission was requested"], exitCode: 77)
    exit(77)
  }
  guard let command = args.first else { throw Failure.message("Missing command") }
  if command == "preflight" {
    try output(["status": "ready", "accessibility": trusted, "eventPosting": posting,
                "launchContext": launchContext()])
    return
  }
  if ["manager-identity", "manager-quit", "manager-kill"].contains(command) {
    guard args.count == 5, let pid = pid_t(args[1]) else { throw Failure.message("Invalid test manager request") }
    try output(testManager(command: command, pid: pid, session: args[2], statePath: args[3], journalPath: args[4]))
    return
  }
  if command == "finder-snapshot" {
    try output(["windows": try finderSnapshot()])
    return
  }
  guard args.count >= 2, let pid = pid_t(args[1]), pid > 1,
    let running = NSRunningApplication(processIdentifier: pid),
    running.bundleIdentifier == "com.google.Chrome"
  else { throw Failure.message("Expected the live PID of the disposable Google Chrome process") }
  let app = AXUIElementCreateApplication(pid)
  _ = AXUIElementSetMessagingTimeout(app, 0.3)
  var current = try windows(pid, app: app)
  if command == "snapshot" {
    let visible = try visibleFrames(pid)
    try output(["pid": pid, "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                "focusedID": focusedID(app, windows: current).map { Int($0) } ?? NSNull(),
                "onscreenIDs": visible.keys.sorted(), "displayWidth": CGDisplayBounds(CGMainDisplayID()).width,
                "onscreenFrames": Dictionary(uniqueKeysWithValues: visible.map { (String($0.key), frameJSON($0.value)) }),
                "windows": current.map { ["id": $0.id, "title": $0.title, "frame": frameJSON($0.frame),
                  "minimized": attribute($0.element, kAXMinimizedAttribute) ?? NSNull()] as [String: Any] }])
    return
  }
  guard args.count >= 3, let id = CGWindowID(args[2]),
    let target = current.first(where: { $0.id == id })
  else { throw Failure.message("Expected a uniquely identified disposable window") }
  if command == "pan-input" {
    guard args.count == 4 else { throw Failure.message("Expected fixture pan input") }
    try output(postFixturePan(args[3], target: target, pid: pid, app: app))
    return
  }
  if command == "gesture" {
    guard args.count == 4 else { throw Failure.message("Expected gesture payload") }
    try output(try mouseGesture(target, pid: pid, app: app, payload: args[3]))
    return
  }
  if command == "focus" {
    guard AXUIElementPerformAction(target.element, kAXRaiseAction as CFString) == .success else {
      throw Failure.message("Cannot raise disposable target")
    }
    _ = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, target.element)
    running.activate()
    let deadline = Date().addingTimeInterval(3)
    repeat {
      current = try windows(pid, app: app)
      if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
        focusedID(app, windows: current) == id { try output(["status": "focused", "id": id]); return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    } while Date() < deadline
    throw Failure.message("Disposable target did not receive native focus")
  }
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
    focusedID(app, windows: current) == id
  else { throw Failure.message("Input refused: the expected disposable target is not frontmost") }
  guard args.count == 4 else { throw Failure.message("Expected command payload") }
  switch command {
  case "shortcut":
    let codes: [String: CGKeyCode] = ["register": 13, "left": 123, "right": 124,
      "newPage": 45, "pageLeft": 33, "pageRight": 30, "togglePause": 35]
    guard let code = codes[args[3]] else { throw Failure.message("Unknown shortcut") }
    try postKey(code, flags: [.maskControl, .maskAlternate, .maskCommand])
  case "type":
    let text = Array(args[3].utf16)
    guard !text.isEmpty, text.count <= 200 else { throw Failure.message("Token length is invalid") }
    for down in [true, false] {
      guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else {
        throw Failure.message("Cannot create Unicode input")
      }
      event.flags = []
      text.withUnsafeBufferPointer { buffer in
        if let base = buffer.baseAddress { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: base) }
      }
      event.postToPid(pid)
    }
  default: throw Failure.message("Unknown command")
  }
  try output(["status": "sent", "command": command, "id": id])
}

do { try MainActor.assumeIsolated { try run() } }
catch {
  var result: [String: Any] = ["status": "FAIL", "reason": String(describing: error)]
  if case Failure.gesturePrecondition(let samples) = error {
    result["reason"] = "Gesture refused: input/foreground precondition did not clear within 600ms; no mouse-down was posted"
    result["guardSamples"] = samples.map(\.json)
  }
  if case Failure.gestureHit(let samples) = error {
    result["reason"] = "Gesture refused: no candidate hit the exact retained AX window and matching layer-0 CG window; no mouse-down was posted"
    result["hitSamples"] = samples.map(\.json)
  }
  try? output(result, exitCode: 1)
  FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
  exit(1)
}
