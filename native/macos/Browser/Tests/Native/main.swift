import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

func check(_ value: Bool, _ message: String) {
  guard value else {
    print("FAIL: \(message)")
    exit(1)
  }
}
let leftMonitor = CGRect(x: -1200, y: 200, width: 800, height: 600)
check(
  nativeAXFrame(fromAppKit: leftMonitor, primaryScreenMaxY: 900)
    == CGRect(x: -1200, y: 100, width: 800, height: 600),
  "AppKit to AX: negative second monitor coordinates")
check(!nativeValidFrame(CGRect(x: CGFloat.nan, y: 0, width: 500, height: 300)), "reject NaN")
check(!nativeValidFrame(CGRect(x: 0, y: 0, width: -100, height: 300)), "reject inverted size")
check(!nativeValidFrame(CGRect(x: 0, y: 0, width: 500, height: 0)), "reject zero height")
let target = CGRect(x: -1000, y: 100, width: 600, height: 400)
check(
  nativeSafeFrame(requested: target, actualSize: CGSize(width: 300, height: 200), screen: target)
    == CGRect(x: -1000, y: 100, width: 300, height: 200),
  "readback accepts smaller application size")
check(
  nativeSafeFrame(requested: target, actualSize: CGSize(width: 640, height: 400), screen: target)
    == nil, "reject application minimum larger than allowed display")
check(
  nativeSafeFrame(
    requested: target, actualSize: CGSize(width: 600, height: CGFloat.infinity), screen: target)
    == nil, "reject invalid AX readback")
check(
  nativeSafeFrame(
    requested: CGRect(x: -400, y: 400, width: 300, height: 200),
    actualSize: CGSize(width: 300, height: 200), screen: target)
    == CGRect(x: -700, y: 300, width: 300, height: 200),
  "clamp actual position within allowed visible desktop")
check(
  !MainActor.assumeIsolated { NativeWindowClient().applications().contains { $0.id == getpid() } },
  "self app excluded without AX permission")
let dockOverlapOriginal = CGRect(x: 49, y: 112, width: 1200, height: 1274)
let visibleDisplay = CGRect(x: 0, y: 30, width: 1728, height: 1318)
check(
  nativeSafeFrame(
    requested: dockOverlapOriginal, actualSize: dockOverlapOriginal.size,
    screen: visibleDisplay) == CGRect(x: 49, y: 74, width: 1200, height: 1274),
  "restore first fits the original size at a temporary higher origin before returning below the Dock"
)
let originalFrame = CGRect(x: 40, y: 50, width: 1088, height: 729)
let requestedFrame = CGRect(x: 300, y: 200, width: 514, height: 376)
var delayedResize = NativeFrameSettlement(requested: requestedFrame, previous: originalFrame)
let staleSize = CGRect(origin: requestedFrame.origin, size: originalFrame.size)
for elapsed in [0.0, 0.04, 0.08, 0.16, 0.28] {
  check(
    !delayedResize.observe(staleSize, elapsed: elapsed),
    "pre-animation size must not become accepted before the settling grace period")
}
check(
  delayedResize.observe(requestedFrame, elapsed: 0.32),
  "asynchronously accepted requested size finishes immediately")
var minimumSize = NativeFrameSettlement(requested: requestedFrame, previous: originalFrame)
let minimumFrame = CGRect(origin: requestedFrame.origin, size: CGSize(width: 600, height: 400))
check(!minimumSize.observe(minimumFrame, elapsed: 0.08), "first fresh sample is insufficient")
check(!minimumSize.observe(minimumFrame, elapsed: 0.12), "second fresh sample is insufficient")
check(
  minimumSize.observe(minimumFrame, elapsed: 0.16), "stable fresh application minimum is accepted")
var delayedRestore = NativeFrameSettlement(requested: originalFrame, previous: requestedFrame)
check(
  !delayedRestore.observe(requestedFrame, elapsed: 0.02), "restore must not accept the moved size")
check(
  !delayedRestore.observe(requestedFrame, elapsed: 0.12),
  "restore waits for asynchronous app geometry")
check(delayedRestore.observe(originalFrame, elapsed: 0.24), "restored original frame is confirmed")
print(
  "PASS: native coordinates, invalid inputs, safe size readback, delayed resize/restore settling and stable application minima"
)
guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--integration" else {
  print("SKIP: pass --integration for isolated cross-process AX placement/restore fixture")
  exit(0)
}
guard AXIsProcessTrusted() else {
  print("SKIP: test host lacks Accessibility; no permission prompt requested")
  exit(77)
}

@MainActor final class Integration: NSObject, NSApplicationDelegate {
  var process: Process?
  let ready = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let client = NativeWindowClient()
  let competitor = NativeWindowClient()
  func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
  func windows(_ client: NativeWindowClient, _ app: NativeWindowApplication) async throws
    -> [NativeWindowChoice]
  {
    try await withCheckedThrowingContinuation { continuation in
      client.discover(application: app) { continuation.resume(with: $0) }
    }
  }
  func place(_ client: NativeWindowClient, _ choice: NativeWindowChoice, _ frame: CGRect)
    async throws -> NativePlacementResult
  {
    try await withCheckedThrowingContinuation { continuation in
      client.place(choice: choice, frame: frame) { continuation.resume(with: $0) }
    }
  }
  func restore() async throws {
    try await withCheckedThrowingContinuation { continuation in
      client.restore { continuation.resume(with: $0) }
    }
  }
  func snapshot(_ pid: pid_t) throws -> [String: CGRect] {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
      let windows = value as? [AXUIElement]
    else { throw NativeWindowError.message("fixture AX list unavailable") }
    var result: [String: CGRect] = [:]
    for window in windows {
      var title: CFTypeRef?
      var position: CFTypeRef?
      var size: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position)
          == .success,
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
        let name = title as? String, let position, let size,
        CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
      else { continue }
      var point = CGPoint.zero
      var dimensions = CGSize.zero
      if AXValueGetValue(position as! AXValue, .cgPoint, &point),
        AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
      {
        result[name] = CGRect(origin: point, size: dimensions)
      }
    }
    return result
  }
  func require(_ value: Bool, _ message: String) throws {
    if !value { throw NativeWindowError.message(message) }
  }
  func run() async {
    do {
      let child = Process()
      child.executableURL = URL(fileURLWithPath: CommandLine.arguments[2])
      child.arguments = [ready.path]
      var environment = ProcessInfo.processInfo.environment
      environment["INFINITEDESK_TALL_FIXTURE"] = "1"
      child.environment = environment
      try child.run()
      process = child
      for _ in 0..<50 {
        if FileManager.default.fileExists(atPath: ready.path) { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard let app = NSRunningApplication(processIdentifier: child.processIdentifier),
        let screen = NSScreen.screens.first
      else { throw NativeWindowError.message("fixture did not start") }
      let application = NativeWindowApplication(
        id: child.processIdentifier, appName: "Native test fixture", suggested: true,
        launchDate: app.launchDate)
      let choices = try await windows(client, application)
      guard let b = choices.first(where: { $0.title.hasSuffix(" B") }) else {
        throw NativeWindowError.message("fixture B missing")
      }
      let original = try snapshot(child.processIdentifier)
      let aTitle = "InfiniteDesk Focus Fixture A"
      let bTitle = "InfiniteDesk Focus Fixture B"
      guard let aBefore = original[aTitle], let bBefore = original[bTitle] else {
        throw NativeWindowError.message("fixture bounds missing")
      }
      let screenAX = nativeAXFrame(
        fromAppKit: screen.visibleFrame, primaryScreenMaxY: screen.frame.maxY)
      let target = CGRect(x: screenAX.minX + 30, y: screenAX.minY + 200, width: 600, height: 420)
      try require(
        bBefore.height > screenAX.height - 40 && bBefore.maxY > screenAX.maxY,
        "tall restore fixture must start partly below the Dock")
      try require(
        target.minY > bBefore.minY + 50,
        "restore regression requires the card lower than the original window")
      let first = try await place(client, b, target)
      try require(
        nativeFramesEqual(first.actualFrame, target), "selected B placement readback mismatch")
      let after = try snapshot(child.processIdentifier)
      try require(after[aTitle] == aBefore, "unselected A moved")
      try require(after[bTitle] == first.actualFrame, "exact B did not move")
      let otherChoices = try await windows(competitor, application)
      guard let otherB = otherChoices.first(where: { $0.title == b.title }) else {
        throw NativeWindowError.message("competitor fixture B missing")
      }
      do {
        _ = try await place(competitor, otherB, target)
        throw NativeWindowError.message("duplicate card ownership was accepted")
      } catch let error as NativeWindowError {
        try require(
          error.localizedDescription.contains("already controls"),
          "wrong duplicate-lease result: \(error)")
      }
      let target2 = target.offsetBy(dx: 25, dy: 20)
      _ = try await place(client, b, target2)
      try await restore()
      try require(
        try snapshot(child.processIdentifier)[bTitle] == bBefore,
        "restoring from a lower card lost tall original bounds below the Dock")
      let clamped = try await place(
        client, b, CGRect(x: target.minX, y: target.minY, width: 80, height: 60))
      try require(clamped.adjusted, "application minimum adjustment was not reported")
      try require(
        clamped.actualFrame.width > 80 && clamped.actualFrame.height > 60,
        "application minimum was not read back")
      try require(
        screenAX.insetBy(dx: -1, dy: -1).contains(clamped.actualFrame),
        "application minimum escaped the visible display")
      try await restore()
      try require(
        try snapshot(child.processIdentifier)[bTitle] == bBefore,
        "minimum-size placement lost original bounds")
      _ = try await place(client, b, target)
      client.close()
      try require(NativeWindowClient.flushOnExit(), "exit flush did not finish")
      try require(
        try snapshot(child.processIdentifier)[bTitle] == bBefore, "exit flush lost original bounds")
      print(
        "PASS: exact B placement; A unchanged; duplicate lease rejected; tall original below Dock restored from lower card; application minimum readback+screen clamp; close+exit restore"
      )
      cleanup()
      exit(0)
    } catch {
      print("FAIL: \(error.localizedDescription)")
      _ = NativeWindowClient.flushOnExit()
      cleanup()
      exit(1)
    }
  }
  func cleanup() {
    competitor.close()
    if let process, process.isRunning { process.terminate() }
    try? FileManager.default.removeItem(at: ready)
  }
}
let app = NSApplication.shared
let delegate = Integration()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
