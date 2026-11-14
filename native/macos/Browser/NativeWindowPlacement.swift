import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

struct NativeWindowApplication: Identifiable, Sendable {
  let id: pid_t
  let appName: String
  let suggested: Bool
  let launchDate: Date?
}

struct NativeWindowChoice: Identifiable, Sendable {
  let id: UUID
  let appName: String
  let title: String
  let pid: pid_t
  let frame: CGRect
  let launchDate: Date?
}

struct NativePlacementResult: Sendable {
  let actualFrame: CGRect
  let adjusted: Bool
}

enum NativeWindowError: LocalizedError, Sendable {
  case message(String)
  var errorDescription: String? {
    switch self {
    case .message(let message): return message
    }
  }
}

func nativeAXFrame(fromAppKit frame: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
  CGRect(x: frame.minX, y: primaryScreenMaxY - frame.maxY, width: frame.width, height: frame.height)
}

func nativeValidFrame(_ frame: CGRect) -> Bool {
  [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
    && frame.size.width >= 80 && frame.size.height >= 60
    && frame.size.width <= 32768 && frame.size.height <= 32768
}

func nativeFramesEqual(_ a: CGRect, _ b: CGRect) -> Bool {
  abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
    && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
}

func nativeSafeFrame(requested: CGRect, actualSize: CGSize, screen: CGRect) -> CGRect? {
  guard
    [
      requested.minX, requested.minY, screen.minX, screen.minY, screen.width, screen.height,
      actualSize.width, actualSize.height,
    ].allSatisfy(\.isFinite),
    screen.width > 0, screen.height > 0,
    actualSize.width > 0, actualSize.height > 0,
    actualSize.width <= screen.width + 1, actualSize.height <= screen.height + 1
  else { return nil }
  return CGRect(
    x: min(max(requested.minX, screen.minX), screen.maxX - actualSize.width),
    y: min(max(requested.minY, screen.minY), screen.maxY - actualSize.height),
    width: actualSize.width, height: actualSize.height)
}

private func nativeAttribute(_ element: AXUIElement, _ name: String, _ gate: WindowFocusGate)
  -> CFTypeRef?
{
  guard gate.isActive() else { return nil }
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
    return nil
  }
  return value
}

private func nativeRect(_ window: AXUIElement, _ gate: WindowFocusGate) -> CGRect? {
  guard let position = nativeAttribute(window, kAXPositionAttribute, gate),
    let size = nativeAttribute(window, kAXSizeAttribute, gate),
    CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
  else { return nil }
  var point = CGPoint.zero
  var dimensions = CGSize.zero
  guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
    AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
  else { return nil }
  let rect = CGRect(origin: point, size: dimensions)
  guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
    rect.width > 0, rect.height > 0
  else { return nil }
  return rect
}

private func nativeSettable(_ window: AXUIElement, _ name: String, _ gate: WindowFocusGate) -> Bool
{
  guard gate.isActive() else { return false }
  var settable = DarwinBoolean(false)
  return AXUIElementIsAttributeSettable(window, name as CFString, &settable) == .success
    && settable.boolValue
}

private func nativeSetSize(_ window: AXUIElement, _ requested: CGSize, _ gate: WindowFocusGate)
  -> Bool
{
  var size = requested
  guard let value = AXValueCreate(.cgSize, &size), gate.isActive() else { return false }
  return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
}

private func nativeSetPosition(_ window: AXUIElement, _ origin: CGPoint, _ gate: WindowFocusGate)
  -> Bool
{
  var point = origin
  guard let position = AXValueCreate(.cgPoint, &point), gate.isActive() else { return false }
  return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
    == .success
}

struct NativeFrameSettlement {
  let requested: CGRect
  let previous: CGRect
  private(set) var last: CGRect?
  private var stableSamples = 0

  mutating func observe(_ frame: CGRect, elapsed: TimeInterval) -> Bool {
    stableSamples = last.map { nativeFramesEqual($0, frame) } == true ? stableSamples + 1 : 1
    last = frame
    if nativeFramesEqual(frame, requested) { return true }
    let unchangedSize =
      abs(frame.width - previous.width) <= 1 && abs(frame.height - previous.height) <= 1
    // A successful AX write may return the pre-animation size for several samples.
    let minimumWait: TimeInterval = unchangedSize ? 0.7 : 0.16
    return stableSamples >= 3 && elapsed >= minimumWait
  }
}

private func nativeSettledFrame(
  _ window: AXUIElement, requested: CGRect, previous: CGRect, gate: WindowFocusGate
) -> CGRect? {
  let started = DispatchTime.now().uptimeNanoseconds
  var settlement = NativeFrameSettlement(requested: requested, previous: previous)
  while gate.isActive() {
    guard let frame = nativeRect(window, gate) else { return nil }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    if settlement.observe(frame, elapsed: elapsed) { return frame }
    guard elapsed < 0.85 else { return nil }
    Thread.sleep(forTimeInterval: 0.04)
  }
  return nil
}

private func nativeSetFrame(_ window: AXUIElement, _ frame: CGRect, _ gate: WindowFocusGate) -> Bool
{
  var point = frame.origin
  var size = frame.size
  guard let position = AXValueCreate(.cgPoint, &point),
    let dimensions = AXValueCreate(.cgSize, &size),
    gate.isActive(),
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions) == .success,
    gate.isActive(),
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success,
    gate.isActive()
  else { return false }
  return true
}

private struct NativeWindowRecord {
  let owner: UUID
  let app: AXUIElement
  let window: AXUIElement
  let choice: NativeWindowChoice
}

private struct NativeWindowSession {
  let record: NativeWindowRecord
  let original: CGRect
  let originalScreen: CGRect?
}

// All AX elements, records, and sessions are confined to this one serial queue.
// Only Sendable DTOs cross to the main actor; no queue work blocks the UI thread.
private final class NativeWindowBackend: @unchecked Sendable {
  static let shared = NativeWindowBackend()
  let queue = DispatchQueue(label: "dev.infinitedesk.native-placement", qos: .userInitiated)
  var records: [UUID: NativeWindowRecord] = [:]
  var sessions: [UUID: NativeWindowSession] = [:]

  func live(_ record: NativeWindowRecord, _ gate: WindowFocusGate) -> Bool {
    var pid: pid_t = 0
    guard gate.isActive(), AXUIElementGetPid(record.window, &pid) == .success,
      pid == record.choice.pid,
      nativeAttribute(record.window, kAXRoleAttribute, gate) as? String == kAXWindowRole,
      let windows = nativeAttribute(record.app, kAXWindowsAttribute, gate) as? [AXUIElement]
    else { return false }
    return windows.contains { CFEqual($0, record.window) }
  }

  func discover(owner: UUID, application: NativeWindowApplication, gate: WindowFocusGate) throws
    -> [NativeWindowChoice]
  {
    let app = AXUIElementCreateApplication(application.id)
    guard AXUIElementSetMessagingTimeout(app, 0.2) == .success,
      let windows = nativeAttribute(app, kAXWindowsAttribute, gate) as? [AXUIElement]
    else {
      throw NativeWindowError.message(
        "This application did not expose its windows. Try another app.")
    }
    guard windows.count <= 80 else {
      throw NativeWindowError.message(
        "This application exposes too many windows. Close some windows and retry.")
    }
    records = records.filter {
      $0.value.owner != owner || sessions[owner]?.record.choice.id == $0.key
    }
    var choices: [NativeWindowChoice] = []
    for window in windows {
      guard gate.isActive() else {
        throw NativeWindowError.message("Window listing timed out. Try another application.")
      }
      guard AXUIElementSetMessagingTimeout(window, 0.2) == .success,
        nativeAttribute(window, kAXRoleAttribute, gate) as? String == kAXWindowRole,
        nativeAttribute(window, kAXSubroleAttribute, gate) as? String == kAXStandardWindowSubrole,
        nativeAttribute(window, "AXFullScreen", gate) as? Bool != true,
        (nativeAttribute(window, kAXMinimizedAttribute, gate) as? Bool) == false,
        let frame = nativeRect(window, gate),
        nativeSettable(window, kAXPositionAttribute, gate),
        nativeSettable(window, kAXSizeAttribute, gate)
      else { continue }
      let title = nativeAttribute(window, kAXTitleAttribute, gate) as? String ?? ""
      let choice = NativeWindowChoice(
        id: UUID(), appName: application.appName,
        title: title.isEmpty ? "Untitled window \(choices.count + 1)" : title,
        pid: application.id, frame: frame,
        launchDate: application.launchDate)
      records[choice.id] = NativeWindowRecord(
        owner: owner, app: app, window: window, choice: choice)
      choices.append(choice)
    }
    return choices
  }

  func place(
    owner: UUID, choice: NativeWindowChoice, frame: CGRect, screen: CGRect, screens: [CGRect],
    gate: WindowFocusGate
  ) throws -> NativePlacementResult {
    guard let record = records[choice.id], record.owner == owner, live(record, gate),
      let current = nativeRect(record.window, gate)
    else {
      throw NativeWindowError.message("The selected window closed or changed. Choose it again.")
    }
    guard
      !sessions.contains(where: {
        $0.key != owner && CFEqual($0.value.record.window, record.window)
      })
    else {
      throw NativeWindowError.message("Another InfiniteDesk card already controls this window.")
    }
    if let previous = sessions[owner], !CFEqual(previous.record.window, record.window) {
      throw NativeWindowError.message("Restore the current window before choosing another.")
    }
    guard nativeSettable(record.window, kAXPositionAttribute, gate),
      nativeSettable(record.window, kAXSizeAttribute, gate)
    else { throw NativeWindowError.message("This window no longer allows movement and resizing.") }
    let originalScreen = screens.max {
      let left = $0.intersection(current)
      let right = $1.intersection(current)
      return (left.isNull ? 0 : left.width * left.height)
        < (right.isNull ? 0 : right.width * right.height)
    }
    sessions[owner] =
      sessions[owner]
      ?? NativeWindowSession(
        record: record, original: current, originalScreen: originalScreen)
    guard nativeSetFrame(record.window, frame, gate),
      let measured = nativeSettledFrame(
        record.window, requested: frame, previous: current, gate: gate)
    else {
      _ = try? restore(owner: owner)
      throw NativeWindowError.message(
        "The window did not accept placement. Restoration was attempted; use Restore to retry.")
    }
    guard
      let safe = nativeSafeFrame(
        requested: frame, actualSize: measured.size, screen: screen)
    else {
      _ = try? restore(owner: owner)
      throw NativeWindowError.message(
        "This window needs at least \(String(format: "%.0f", ceil(measured.width))) × \(String(format: "%.0f", ceil(measured.height))) points, exceeding the visible display. Use Restore and choose a larger display or another window."
      )
    }
    var actual = measured
    if abs(safe.minX - measured.minX) > 1 || abs(safe.minY - measured.minY) > 1 {
      guard nativeSetPosition(record.window, safe.origin, gate),
        let positioned = nativeSettledFrame(
          record.window, requested: safe, previous: measured, gate: gate),
        nativeFramesEqual(positioned, safe)
      else {
        _ = try? restore(owner: owner)
        throw NativeWindowError.message(
          "The application did not accept a safe position. Use Restore to retry.")
      }
      actual = positioned
    }
    guard live(record, gate),
      gate.isActive(),
      AXUIElementPerformAction(record.window, kAXRaiseAction as CFString) == .success
    else {
      // Keep the original handle if rollback fails so Restore can retry restoration.
      _ = try? restore(owner: owner)
      throw NativeWindowError.message(
        "The window did not accept placement. Restoration was attempted; use Restore to retry.")
    }
    var focused = false
    for _ in 0..<8 {
      guard gate.isActive() else { break }
      if let selected = nativeAttribute(record.app, kAXFocusedWindowAttribute, gate),
        CFEqual(selected, record.window)
      {
        focused = true
        break
      }
      Thread.sleep(forTimeInterval: 0.04)
    }
    guard focused else {
      _ = try? restore(owner: owner)
      throw NativeWindowError.message(
        "Could not confirm focus on the selected window. Use Restore to restore if needed.")
    }
    return NativePlacementResult(actualFrame: actual, adjusted: !nativeFramesEqual(actual, frame))
  }

  func restore(owner: UUID) throws {
    guard let session = sessions[owner] else { return }
    let gate = WindowFocusGate()
    var role: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
      session.record.window, kAXRoleAttribute as CFString, &role)
    if status == .invalidUIElement {
      sessions.removeValue(forKey: owner)
      return
    }
    guard status == .success, live(session.record, gate) else {
      throw NativeWindowError.message(
        "The source window is temporarily inaccessible. Restore can be retried.")
    }
    let window = session.record.window
    let original = session.original
    let fitting =
      session.originalScreen.flatMap {
        nativeSafeFrame(requested: original, actualSize: original.size, screen: $0)
      } ?? original
    guard let before = nativeRect(window, gate),
      nativeSetPosition(window, fitting.origin, gate),
      let positioned = nativeSettledFrame(
        window, requested: CGRect(origin: fitting.origin, size: before.size), previous: before,
        gate: gate),
      abs(positioned.minX - fitting.minX) <= 1, abs(positioned.minY - fitting.minY) <= 1,
      nativeSetSize(window, original.size, gate),
      let resized = nativeSettledFrame(
        window, requested: fitting, previous: positioned, gate: gate),
      nativeFramesEqual(resized, fitting)
    else {
      throw NativeWindowError.message(
        "The application did not restore its original size and position. The saved bounds remain available; try Restore again."
      )
    }
    if !nativeFramesEqual(fitting, original) {
      guard nativeSetPosition(window, original.origin, gate),
        let actual = nativeSettledFrame(window, requested: original, previous: resized, gate: gate),
        nativeFramesEqual(actual, original)
      else {
        throw NativeWindowError.message(
          "The application refused the saved position outside the visible display. The saved bounds remain available; try Restore again."
        )
      }
    }
    sessions.removeValue(forKey: owner)
  }
}

@MainActor
final class NativeWindowClient {
  private let id = UUID()
  private var busy = false
  private var closed = false
  private var operation: WindowFocusGate?

  func applications() -> [NativeWindowApplication] {
    let entries =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    var order: [pid_t] = []
    for entry in entries {
      guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != getpid(),
        !order.contains(pid),
        let bounds = entry[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        rect.width >= 80, rect.height >= 60
      else { continue }
      order.append(pid)
    }
    let apps = NSWorkspace.shared.runningApplications.filter {
      $0.processIdentifier != getpid() && !$0.isTerminated && $0.activationPolicy == .regular
    }
    return apps.map { app in
      NativeWindowApplication(
        id: app.processIdentifier,
        appName: app.localizedName ?? "Application \(app.processIdentifier)",
        suggested: app.processIdentifier == order.first, launchDate: app.launchDate)
    }.sorted {
      let left = order.firstIndex(of: $0.id) ?? Int.max
      let right = order.firstIndex(of: $1.id) ?? Int.max
      return left == right
        ? $0.appName.localizedStandardCompare($1.appName) == .orderedAscending : left < right
    }
  }

  private func allowed() -> NativeWindowError? {
    guard !closed else { return .message("This card has closed.") }
    guard !busy else { return .message("A native window operation is already running.") }
    guard AXIsProcessTrusted() else {
      let options =
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
      return .message(
        "Allow InfiniteDesk in System Settings → Privacy & Security → Accessibility, then retry.")
    }
    return nil
  }

  func discover(
    application: NativeWindowApplication,
    completion:
      @escaping @MainActor @Sendable (Result<[NativeWindowChoice], NativeWindowError>) -> Void
  ) {
    if let error = allowed() {
      completion(.failure(error))
      return
    }
    guard let app = NSRunningApplication(processIdentifier: application.id),
      !app.isTerminated, app.launchDate == application.launchDate
    else {
      completion(.failure(.message("This application exited. Open the app chooser again.")))
      return
    }
    busy = true
    let owner = id
    let gate = WindowFocusGate()
    operation = gate
    NativeWindowBackend.shared.queue.async { [weak self] in
      let result: Result<[NativeWindowChoice], NativeWindowError>
      do {
        result = .success(
          try NativeWindowBackend.shared.discover(
            owner: owner, application: application, gate: gate))
      } catch {
        result = .failure((error as? NativeWindowError) ?? .message(error.localizedDescription))
      }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.busy = false
        if !self.closed { completion(result) }
      }
    }
  }

  func place(
    choice: NativeWindowChoice, frame: CGRect,
    completion:
      @escaping @MainActor @Sendable (Result<NativePlacementResult, NativeWindowError>) -> Void
  ) {
    if let error = allowed() {
      completion(.failure(error))
      return
    }
    guard nativeValidFrame(frame) else {
      completion(.failure(.message("The card is too small or outside valid desktop coordinates.")))
      return
    }
    guard let app = NSRunningApplication(processIdentifier: choice.pid), !app.isTerminated,
      app.launchDate == choice.launchDate
    else {
      completion(.failure(.message("The source application exited. Choose another window.")))
      return
    }
    guard let primary = NSScreen.screens.first else {
      completion(.failure(.message("No display is available.")))
      return
    }
    let screens = NSScreen.screens.map {
      nativeAXFrame(fromAppKit: $0.visibleFrame, primaryScreenMaxY: primary.frame.maxY)
    }
    guard
      let screen = screens.max(by: {
        $0.intersection(frame).width * $0.intersection(frame).height < $1.intersection(frame).width
          * $1.intersection(frame).height
      }),
      !screen.intersection(frame).isNull, app.activate()
    else {
      completion(.failure(.message("Cannot activate the application on the selected screen.")))
      return
    }
    busy = true
    let owner = id
    let gate = WindowFocusGate()
    operation = gate
    NativeWindowBackend.shared.queue.async { [weak self] in
      let result: Result<NativePlacementResult, NativeWindowError>
      do {
        result = .success(
          try NativeWindowBackend.shared.place(
            owner: owner, choice: choice, frame: frame, screen: screen, screens: screens, gate: gate
          ))
      } catch {
        result = .failure((error as? NativeWindowError) ?? .message(error.localizedDescription))
      }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.busy = false
        guard !self.closed else { return }
        switch result {
        case .success:
          guard !app.isTerminated, app.launchDate == choice.launchDate,
            NSWorkspace.shared.frontmostApplication == app
          else {
            completion(
              .failure(
                .message(
                  "Placed the window, but the application could not activate. Use Restore to restore."
                )
              ))
            return
          }
        case .failure: break
        }
        completion(result)
      }
    }
  }

  func restore(completion: @escaping @MainActor @Sendable (Result<Void, NativeWindowError>) -> Void)
  {
    guard !closed else {
      completion(.failure(.message("This card has closed.")))
      return
    }
    guard !busy else {
      completion(.failure(.message("Wait for the current window operation.")))
      return
    }
    busy = true
    let owner = id
    NativeWindowBackend.shared.queue.async { [weak self] in
      let result: Result<Void, NativeWindowError>
      do {
        try NativeWindowBackend.shared.restore(owner: owner)
        result = .success(())
      } catch {
        result = .failure((error as? NativeWindowError) ?? .message(error.localizedDescription))
      }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.busy = false
        if !self.closed { completion(result) }
      }
    }
  }

  func close() {
    guard !closed else { return }
    closed = true
    operation?.cancel()
    let owner = id
    NativeWindowBackend.shared.queue.async {
      try? NativeWindowBackend.shared.restore(owner: owner)
      NativeWindowBackend.shared.records = NativeWindowBackend.shared.records.filter {
        $0.value.owner != owner
      }
    }
  }

  // Called only after the event loop stops; the backend does not depend on the main queue.
  nonisolated static func flushOnExit() -> Bool {
    let status = NativeExitStatus()
    NativeWindowBackend.shared.queue.async {
      for owner in Array(NativeWindowBackend.shared.sessions.keys) {
        try? NativeWindowBackend.shared.restore(owner: owner)
      }
      status.finish(success: NativeWindowBackend.shared.sessions.isEmpty)
    }
    return status.wait()
  }

}

@_cdecl("desk_browser_finish_native_windows")
public func deskBrowserFinishNativeWindows() -> UInt8 {
  NativeWindowClient.flushOnExit() ? 1 : 0
}

// The semaphore bounds shutdown; the lock protects the result across its timeout path.
private final class NativeExitStatus: @unchecked Sendable {
  private let lock = NSLock()
  private let done = DispatchSemaphore(value: 0)
  private var success = false
  func finish(success: Bool) {
    lock.lock()
    self.success = success
    lock.unlock()
    done.signal()
  }
  func wait() -> Bool {
    guard done.wait(timeout: .now() + 5) == .success else { return false }
    lock.lock()
    defer { lock.unlock() }
    return success
  }
}
