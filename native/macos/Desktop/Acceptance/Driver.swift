import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum Failure: Error { case message(String) }

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

struct Window {
  let id: CGWindowID
  let element: AXUIElement
  let frame: CGRect
  let title: String
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
    event.flags = flags.union(intrinsic)
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
  guard args.count >= 2, let pid = pid_t(args[1]), pid > 1,
    let running = NSRunningApplication(processIdentifier: pid),
    running.bundleIdentifier == "com.google.Chrome"
  else { throw Failure.message("Expected the live PID of the disposable Google Chrome process") }
  let app = AXUIElementCreateApplication(pid)
  _ = AXUIElementSetMessagingTimeout(app, 0.3)
  var current = try windows(pid, app: app)
  if command == "snapshot" {
    try output(["pid": pid, "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                "focusedID": focusedID(app, windows: current).map { Int($0) } ?? NSNull(),
                "windows": current.map { ["id": $0.id, "title": $0.title, "frame": frameJSON($0.frame)] as [String: Any] }])
    return
  }
  guard args.count >= 3, let id = CGWindowID(args[2]),
    let target = current.first(where: { $0.id == id })
  else { throw Failure.message("Expected a uniquely identified disposable window") }
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
    let codes: [String: CGKeyCode] = ["register": 13, "left": 123, "right": 124]
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
  try? output(["status": "FAIL", "reason": String(describing: error)], exitCode: 1)
  FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
  exit(1)
}
