import AppKit
@preconcurrency import ApplicationServices
import Darwin
import Foundation
import OSLog

struct DesktopProcessIdentity: Equatable, Sendable {
  let seconds: UInt64
  let microseconds: UInt64

  static func read(pid: pid_t) -> Self? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
    return Self(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
  }
}

struct DesktopApplicationSnapshot: Sendable {
  let pid: pid_t
  let launchDate: Date?
  let appName: String
  let bundleIdentifier: String?
  let processIdentity: DesktopProcessIdentity
}

struct DesktopWindow: Identifiable, Sendable {
  let id: UUID
  let pid: pid_t
  let appName: String
  let title: String
  let originalFrame: CGRect
  let launchDate: Date?
  let processIdentity: DesktopProcessIdentity
}

func desktopLaunchDatesCompatible(expected: Date?, actual: Date?) -> Bool {
  guard let expected, let actual else { return true }
  return expected == actual
}

enum DesktopWindowError: LocalizedError, Sendable {
  case message(String)
  case focusUnconfirmed

  var errorDescription: String? {
    switch self {
    case .message(let text): return text
    case .focusUnconfirmed: return "Could not confirm keyboard focus on the exact selected window."
    }
  }
}

// Cancellation is shared with the main actor; AX objects themselves never leave the worker queue.
final class DesktopOperation: @unchecked Sendable {
  private let lock = NSLock()
  private var active = true
  private let deadline: DispatchTime

  init(timeout: TimeInterval = 3) {
    deadline = .now() + timeout
  }

  func check() throws {
    lock.lock()
    defer { lock.unlock() }
    guard active, DispatchTime.now() < deadline else {
      throw DesktopWindowError.message("Window operation cancelled or timed out.")
    }
  }

  func cancel() {
    lock.lock()
    active = false
    lock.unlock()
  }
}

// Only Raise and Main are exposed as mutations; registration has no geometry setter.
protocol DesktopAXAccess: AnyObject {
  func application(pid: pid_t) -> AXUIElement
  func timeout(_ element: AXUIElement) -> Bool
  func read(_ element: AXUIElement, _ name: String) -> CFTypeRef?
  func pid(_ element: AXUIElement) -> pid_t?
  func perform(_ element: AXUIElement, _ action: String) -> AXError
  func mainSettable(_ element: AXUIElement) -> Bool
  func makeMain(_ element: AXUIElement) -> AXError
}

final class SystemDesktopAXAccess: DesktopAXAccess {
  func application(pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }
  func timeout(_ element: AXUIElement) -> Bool {
    AXUIElementSetMessagingTimeout(element, 0.15) == .success
  }
  func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }
  func pid(_ element: AXUIElement) -> pid_t? {
    var pid: pid_t = 0
    return AXUIElementGetPid(element, &pid) == .success ? pid : nil
  }
  func perform(_ element: AXUIElement, _ action: String) -> AXError {
    AXUIElementPerformAction(element, action as CFString)
  }
  func mainSettable(_ element: AXUIElement) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, kAXMainAttribute as CFString, &settable) == .success
      && settable.boolValue
  }
  func makeMain(_ element: AXUIElement) -> AXError {
    AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
  }
}

private struct DesktopWindowRecord {
  let application: DesktopApplicationSnapshot
  let app: AXUIElement
  let window: AXUIElement
  let snapshot: DesktopWindow
}

// All access to records and AX handles is confined to queue. Only DTOs cross its boundary.
final class DesktopWindowBackend: @unchecked Sendable {
  let queue = DispatchQueue(label: "dev.infinitedesk.desktop-ax", qos: .userInitiated)
  private let access: any DesktopAXAccess
  private let processIdentity: @Sendable (pid_t) -> DesktopProcessIdentity?
  private var records: [UUID: DesktopWindowRecord] = [:]
  private var pendingRegistrations: [UUID: DesktopOperation] = [:]

  init(
    access: any DesktopAXAccess = SystemDesktopAXAccess(),
    processIdentity: @escaping @Sendable (pid_t) -> DesktopProcessIdentity? = {
      DesktopProcessIdentity.read(pid: $0)
    }
  ) {
    self.access = access
    self.processIdentity = processIdentity
  }

  private func read(_ element: AXUIElement, _ name: String, _ operation: DesktopOperation) throws
    -> CFTypeRef?
  {
    try operation.check()
    let result = access.read(element, name)
    try operation.check()
    return result
  }

  private func validateProcess(_ application: DesktopApplicationSnapshot, _ operation: DesktopOperation)
    throws
  {
    try operation.check()
    guard processIdentity(application.pid) == application.processIdentity else {
      throw DesktopWindowError.message("The application exited or restarted. Register its window again.")
    }
  }

  private func frame(_ window: AXUIElement, _ operation: DesktopOperation) throws -> CGRect {
    guard let position = try read(window, kAXPositionAttribute, operation),
      let size = try read(window, kAXSizeAttribute, operation),
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
    else { throw DesktopWindowError.message("Cannot read the window's current bounds.") }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetType(position as! AXValue) == .cgPoint,
      AXValueGetType(size as! AXValue) == .cgSize,
      AXValueGetValue(position as! AXValue, .cgPoint, &point),
      AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
      [point.x, point.y, dimensions.width, dimensions.height].allSatisfy(\.isFinite),
      dimensions.width > 0, dimensions.height > 0
    else { throw DesktopWindowError.message("The window returned invalid bounds.") }
    return CGRect(origin: point, size: dimensions)
  }

  private func validateWindow(_ record: DesktopWindowRecord, _ operation: DesktopOperation) throws {
    try validateProcess(record.application, operation)
    try operation.check()
    guard access.pid(record.window) == record.application.pid,
      try read(record.window, kAXRoleAttribute, operation) as? String == kAXWindowRole,
      try read(record.window, kAXSubroleAttribute, operation) as? String == kAXStandardWindowSubrole,
      try read(record.window, kAXMinimizedAttribute, operation) as? Bool == false,
      try read(record.window, "AXFullScreen", operation) as? Bool == false,
      let windows = try read(record.app, kAXWindowsAttribute, operation) as? [AXUIElement],
      windows.count <= 256, windows.contains(where: { CFEqual($0, record.window) })
    else {
      throw DesktopWindowError.message(
        "The exact registered window is unavailable, minimized, or fullscreen. Register it again.")
    }
    _ = try frame(record.window, operation)
    try validateProcess(record.application, operation)
  }

  func capture(
    application: DesktopApplicationSnapshot, operation: DesktopOperation
  ) throws -> DesktopWindow {
    try validateProcess(application, operation)
    let app = access.application(pid: application.pid)
    guard access.timeout(app),
      let value = try read(app, kAXFocusedWindowAttribute, operation),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { throw DesktopWindowError.message("This application has no accessible focused window.") }
    let window = value as! AXUIElement
    guard access.timeout(window) else {
      throw DesktopWindowError.message("The window did not accept an Accessibility timeout.")
    }
    let temporary = DesktopWindowRecord(
      application: application, app: app, window: window,
      snapshot: DesktopWindow(
        id: UUID(), pid: application.pid, appName: application.appName, title: "",
        originalFrame: .zero, launchDate: application.launchDate,
        processIdentity: application.processIdentity))
    try validateWindow(temporary, operation)
    if let existing = records.values.first(where: {
      $0.application.processIdentity == application.processIdentity
        && pendingRegistrations[$0.snapshot.id] == nil
        && $0.application.pid == application.pid && CFEqual($0.window, window)
    }) {
      guard let focused = try read(app, kAXFocusedWindowAttribute, operation), CFEqual(focused, window)
      else { throw DesktopWindowError.message("Focus changed during registration. Retry with the intended window.") }
      try validateProcess(application, operation)
      return existing.snapshot
    }
    let title = try read(window, kAXTitleAttribute, operation) as? String ?? ""
    let snapshot = DesktopWindow(
      id: UUID(), pid: application.pid, appName: application.appName,
      title: title.isEmpty ? "Untitled window" : title,
      originalFrame: try frame(window, operation), launchDate: application.launchDate,
      processIdentity: application.processIdentity)
    guard let focused = try read(app, kAXFocusedWindowAttribute, operation), CFEqual(focused, window)
    else { throw DesktopWindowError.message("Focus changed during registration. Retry with the intended window.") }
    try validateProcess(application, operation)
    try operation.check()
    records[snapshot.id] = DesktopWindowRecord(
      application: application, app: app, window: window, snapshot: snapshot)
    pendingRegistrations[snapshot.id] = operation
    return snapshot
  }

  func prepare(id: UUID, operation: DesktopOperation) throws -> DesktopWindow {
    guard let record = records[id] else {
      throw DesktopWindowError.message("This window is no longer registered.")
    }
    try validateWindow(record, operation)
    return record.snapshot
  }

  func raise(id: UUID, operation: DesktopOperation) throws {
    guard let record = records[id] else {
      throw DesktopWindowError.message("This window is no longer registered.")
    }
    try validateWindow(record, operation)
    try operation.check()
    let status = access.perform(record.window, kAXRaiseAction)
    try operation.check()
    // cannotComplete can follow a delivered action; confirm by reading focus without retrying Raise.
    guard status == .success || status == .cannotComplete else {
      throw DesktopWindowError.message("The application refused to raise the selected window (AX \(status.rawValue)).")
    }
  }

  func makeMain(id: UUID, operation: DesktopOperation) throws {
    guard let record = records[id] else {
      throw DesktopWindowError.message("This window is no longer registered.")
    }
    try validateWindow(record, operation)
    if let focused = try read(record.app, kAXFocusedWindowAttribute, operation),
      CFEqual(focused, record.window)
    { return }
    try operation.check()
    guard access.mainSettable(record.window) else { throw DesktopWindowError.focusUnconfirmed }
    try validateProcess(record.application, operation)
    try operation.check()
    let status = access.makeMain(record.window)
    try operation.check()
    guard status == .success || status == .cannotComplete else {
      throw DesktopWindowError.message("The application refused Main on the selected window (AX \(status.rawValue)).")
    }
  }

  func confirm(id: UUID, operation: DesktopOperation, attempts: Int = 8) throws -> DesktopWindow {
    guard let record = records[id] else {
      throw DesktopWindowError.message("This window is no longer registered.")
    }
    for _ in 0..<attempts {
      try validateProcess(record.application, operation)
      if let focused = try read(record.app, kAXFocusedWindowAttribute, operation),
        CFEqual(focused, record.window)
      {
        try validateWindow(record, operation)
        if let current = try read(record.app, kAXFocusedWindowAttribute, operation),
          CFEqual(current, record.window)
        { return record.snapshot }
      }
      Thread.sleep(forTimeInterval: 0.04)
    }
    throw DesktopWindowError.focusUnconfirmed
  }

  func commit(id: UUID, operation: DesktopOperation) {
    guard pendingRegistrations[id] === operation else { return }
    pendingRegistrations.removeValue(forKey: id)
  }

  func discardPending() {
    for id in pendingRegistrations.keys { records.removeValue(forKey: id) }
    pendingRegistrations.removeAll()
  }

  func remove(id: UUID) {
    records.removeValue(forKey: id)
    pendingRegistrations.removeValue(forKey: id)
  }
  func removeAll() {
    records.removeAll()
    pendingRegistrations.removeAll()
  }
}

@MainActor
final class DesktopWindowClient {
  private let backend = DesktopWindowBackend()
  private var operation: DesktopOperation?
  private var timeout: DispatchWorkItem?
  private var applications: [UUID: DesktopApplicationSnapshot] = [:]
  private static let snapshotLogger = Logger(subsystem: "dev.infinitedesk.desktop", category: "snapshot")
  private var closed = false
  private(set) var windows: [DesktopWindow] = []

  static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

  static func requestAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  static func snapshot(_ app: NSRunningApplication?) -> DesktopApplicationSnapshot? {
    guard let app else {
      snapshotLogger.error("snapshot rejected reason=no_frontmost_application")
      return nil
    }
    let pid = app.processIdentifier
    guard pid != getpid() else {
      snapshotLogger.error("snapshot rejected reason=own_application pid=\(pid)")
      return nil
    }
    guard !app.isTerminated else {
      snapshotLogger.error("snapshot rejected reason=terminated pid=\(pid)")
      return nil
    }
    guard app.activationPolicy == .regular else {
      snapshotLogger.error("snapshot rejected reason=not_regular pid=\(pid) policy=\(app.activationPolicy.rawValue)")
      return nil
    }
    guard let identity = DesktopProcessIdentity.read(pid: pid) else {
      snapshotLogger.error("snapshot rejected reason=unavailable_process_identity pid=\(pid) errno=\(errno)")
      return nil
    }
    snapshotLogger.info("snapshot accepted pid=\(pid) launch_date_available=\(app.launchDate != nil)")
    return DesktopApplicationSnapshot(
      pid: pid, launchDate: app.launchDate,
      appName: app.localizedName ?? "Application \(pid)",
      bundleIdentifier: app.bundleIdentifier, processIdentity: identity)
  }

  private func begin(
    completion: @escaping @MainActor @Sendable (Result<DesktopWindow, DesktopWindowError>) -> Void
  ) -> DesktopOperation? {
    cancel()
    guard !closed else {
      completion(.failure(.message("The desktop manager has stopped.")))
      return nil
    }
    guard Self.accessibilityTrusted else {
      completion(.failure(.message("Allow InfiniteDesk in System Settings → Privacy & Security → Accessibility.")))
      return nil
    }
    let operation = DesktopOperation()
    self.operation = operation
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, self.operation === operation else { return }
      self.operation = nil
      self.timeout = nil
      operation.cancel()
      let backend = self.backend
      backend.queue.async { backend.discardPending() }
      completion(.failure(.message("The window did not respond within three seconds.")))
    }
    self.timeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
    return operation
  }

  private func finish(
    operation: DesktopOperation, result: Result<DesktopWindow, DesktopWindowError>,
    completion: @MainActor @Sendable (Result<DesktopWindow, DesktopWindowError>) -> Void
  ) {
    guard !closed, self.operation === operation else { return }
    timeout?.cancel()
    timeout = nil
    self.operation = nil
    operation.cancel()
    completion(result)
  }

  private func liveApplication(_ snapshot: DesktopApplicationSnapshot) -> NSRunningApplication? {
    guard let app = NSRunningApplication(processIdentifier: snapshot.pid), !app.isTerminated,
      DesktopProcessIdentity.read(pid: snapshot.pid) == snapshot.processIdentity,
      desktopLaunchDatesCompatible(expected: snapshot.launchDate, actual: app.launchDate)
    else { return nil }
    return app
  }

  func captureFocused(
    application: DesktopApplicationSnapshot,
    completion: @escaping @MainActor @Sendable (Result<DesktopWindow, DesktopWindowError>) -> Void
  ) {
    guard let operation = begin(completion: completion) else { return }
    guard liveApplication(application) != nil else {
      finish(operation: operation, result: .failure(.message("The application exited. Select its window again.")), completion: completion)
      return
    }
    let backend = backend
    backend.queue.async { [weak self] in
      let result = Result { try backend.capture(application: application, operation: operation) }
        .mapError { ($0 as? DesktopWindowError) ?? .message($0.localizedDescription) }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.operation === operation else { return }
        var final = result
        if case .success(let window) = result {
          guard self.liveApplication(application) != nil else {
            self.finish(operation: operation, result: .failure(.message("The application exited during registration.")), completion: completion)
            return
          }
          do {
            try operation.check()
            backend.queue.async { backend.commit(id: window.id, operation: operation) }
            if !self.windows.contains(where: { $0.id == window.id }) { self.windows.append(window) }
            self.applications[window.id] = application
          } catch {
            backend.queue.async { backend.discardPending() }
            final = .failure(.message("Window registration timed out."))
          }
        }
        self.finish(operation: operation, result: final, completion: completion)
      }
    }
  }

  func focus(
    id: UUID,
    completion: @escaping @MainActor @Sendable (Result<DesktopWindow, DesktopWindowError>) -> Void
  ) {
    guard let operation = begin(completion: completion) else { return }
    guard let application = applications[id],
      let app = liveApplication(application), windows.contains(where: { $0.id == id })
    else {
      finish(operation: operation, result: .failure(.message("The registered application exited. Register its window again.")), completion: completion)
      return
    }
    let backend = backend
    backend.queue.async { [weak self] in
      do {
        _ = try backend.prepare(id: id, operation: operation)
      } catch {
        let failure = (error as? DesktopWindowError) ?? .message(error.localizedDescription)
        DispatchQueue.main.async { [weak self] in
          self?.finish(operation: operation, result: .failure(failure), completion: completion)
        }
        return
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.operation === operation else { return }
        do { try operation.check() } catch { return }
        guard self.liveApplication(application) != nil,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == application.pid || app.activate()
        else {
          self.finish(operation: operation, result: .failure(.message("The selected application could not activate.")), completion: completion)
          return
        }
        backend.queue.async { [weak self] in
          let result = Result {
            try backend.raise(id: id, operation: operation)
            return try backend.confirm(id: id, operation: operation, attempts: 3)
          }.mapError { ($0 as? DesktopWindowError) ?? .message($0.localizedDescription) }
          DispatchQueue.main.async { [weak self] in
            self?.finishFocus(
              id: id, application: application, operation: operation, result: result,
              allowMainFallback: true, completion: completion)
          }
        }
      }
    }
  }

  private func finishFocus(
    id: UUID, application: DesktopApplicationSnapshot, operation: DesktopOperation,
    result: Result<DesktopWindow, DesktopWindowError>, allowMainFallback: Bool,
    completion: @escaping @MainActor @Sendable (Result<DesktopWindow, DesktopWindowError>) -> Void
  ) {
    guard self.operation === operation else { return }
    guard liveApplication(application) != nil,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == application.pid
    else {
      finish(operation: operation, result: .failure(.message("The selected application did not retain keyboard focus.")), completion: completion)
      return
    }
    if case .failure(.focusUnconfirmed) = result, allowMainFallback {
      do { try operation.check() } catch { return }
      let backend = backend
      backend.queue.async { [weak self] in
        let fallback = Result {
          try backend.makeMain(id: id, operation: operation)
          return try backend.confirm(id: id, operation: operation)
        }.mapError { ($0 as? DesktopWindowError) ?? .message($0.localizedDescription) }
        DispatchQueue.main.async { [weak self] in
          self?.finishFocus(
            id: id, application: application, operation: operation, result: fallback,
            allowMainFallback: false, completion: completion)
        }
      }
      return
    }
    var final = result
    if case .success = result {
      do { try operation.check() } catch {
        final = .failure(.message("Window focus timed out."))
      }
    }
    finish(operation: operation, result: final, completion: completion)
  }

  func cancel() {
    operation?.cancel()
    operation = nil
    timeout?.cancel()
    timeout = nil
    let backend = backend
    backend.queue.async { backend.discardPending() }
  }

  func remove(id: UUID) {
    cancel()
    windows.removeAll { $0.id == id }
    applications.removeValue(forKey: id)
    let backend = backend
    backend.queue.async { backend.remove(id: id) }
  }

  func close() {
    cancel()
    closed = true
    windows.removeAll()
    applications.removeAll()
    let backend = backend
    backend.queue.async { backend.removeAll() }
  }
}
