import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

func testMatching() -> Bool {
  let a = CGRect(x: 10, y: 20, width: 100, height: 100)
  let b = CGRect(x: 300, y: 20, width: 120, height: 110)
  let ca = FocusGeometry(id: 1, rect: a, title: nil)
  let cb = FocusGeometry(id: 2, rect: b, title: nil)
  return uniqueFocusMatch(target: 1, cg: [ca, cb], ax: [b, a]) == 1
    && uniqueFocusMatch(target: 3, cg: [ca, cb], ax: [a, b]) == nil
    && uniqueFocusMatch(target: 1, cg: [ca, FocusGeometry(id: 3, rect: a, title: nil)], ax: [a])
      == nil
    && uniqueFocusMatch(target: 1, cg: [ca], ax: [a, a]) == nil
    && uniqueFocusMatch(target: 1, cg: [ca], ax: [b]) == nil
    && focusTitlesMatch(cg: "Tab", ax: "Tab - Google Chrome", bundleID: "com.google.Chrome")
    && !focusTitlesMatch(cg: "Tab", ax: "Tab - Google Chrome", bundleID: "other")
}

@MainActor final class SelfFocusResult {
  var message: String?
  var calls = 0
}

let selfFocusPassed = MainActor.assumeIsolated {
  let result = SelfFocusResult()
  let gate = WindowFocusGate()
  requestWindowFocus(
    identity: WindowFocusIdentity(windowID: 1, pid: getpid()),
    app: NSRunningApplication.current, gate: gate
  ) { message in
    result.message = message
    result.calls += 1
  }
  return result.calls == 1 && result.message == "Cannot focus a window in InfiniteDesk itself."
    && !gate.isActive()
}
guard selfFocusPassed else {
  print("FAIL: self PID must be rejected synchronously and cancel its gate")
  exit(1)
}
print("PASS: self PID rejected synchronously without AX")

guard testMatching() else {
  print("FAIL: identity matching")
  exit(1)
}
print("PASS: unique, ambiguous, missing and Chrome-title matching")
guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--integration" else {
  print("SKIP: pass --integration <fixture> for cross-process AX smoke")
  exit(0)
}
guard AXIsProcessTrusted() else {
  print("SKIP: this test host lacks Accessibility access; no permission was requested")
  exit(77)
}

@MainActor final class Integration: NSObject, NSApplicationDelegate {
  var child: Process?
  let idFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
  func focus(_ identity: WindowFocusIdentity, app: NSRunningApplication) async -> String {
    await withCheckedContinuation { continuation in
      requestWindowFocus(identity: identity, app: app, gate: WindowFocusGate()) { message in
        continuation.resume(returning: message)
      }
    }
  }
  func run() async {
    do {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[2])
      process.arguments = [idFile.path]
      try process.run()
      child = process
      var values: [UInt32] = []
      for _ in 0..<50 {
        if let data = try? String(contentsOf: idFile, encoding: .utf8) {
          values = data.split(separator: " ").compactMap {
            UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines))
          }
          if values.count == 2 { break }
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard values.count == 2,
        let running = NSRunningApplication(processIdentifier: process.processIdentifier)
      else {
        fail("fixture did not start")
        return
      }
      let a = WindowFocusIdentity(windowID: values[0], pid: process.processIdentifier)
      let b = WindowFocusIdentity(windowID: values[1], pid: process.processIdentifier)
      for identity in [a, b] {
        let result = await focus(identity, app: running)
        guard result == "Selected window focused." else {
          fail("focus failed: \(result)")
          return
        }
        let focused = await Task.detached {
          testFocusedWindow(identity, bundleID: running.bundleIdentifier)
        }.value
        guard focused == true else {
          fail("focused AX window mismatch")
          return
        }
      }
      print("PASS: cross-process production focus A/B")
      cleanup()
      exit(0)
    } catch { fail(error.localizedDescription) }
  }
  func cleanup() {
    if let child, child.isRunning { child.terminate() }
    try? FileManager.default.removeItem(at: idFile)
  }
  func fail(_ message: String) {
    print("FAIL: \(message)")
    cleanup()
    exit(1)
  }
}
let app = NSApplication.shared
let delegate = Integration()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
