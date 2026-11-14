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

enum DesktopWindowAvailability: String, Sendable { case available, unavailable, closed }
enum DesktopObservationStatus: String, Sendable { case pending, observing, partial, unsupported, paused }

struct DesktopWindow: Identifiable, Equatable, Sendable {
  let id: UUID
  let pid: pid_t
  let appName: String
  let title: String
  let originalFrame: CGRect
  let launchDate: Date?
  let processIdentity: DesktopProcessIdentity
  var worldFrame: CGRect
  var availability = DesktopWindowAvailability.available
  var observationStatus = DesktopObservationStatus.pending
  var observationDetail: String?

  init(
    id: UUID, pid: pid_t, appName: String, title: String, originalFrame: CGRect,
    launchDate: Date?, processIdentity: DesktopProcessIdentity
  ) {
    self.id = id
    self.pid = pid
    self.appName = appName
    self.title = title
    self.originalFrame = originalFrame
    self.launchDate = launchDate
    self.processIdentity = processIdentity
    worldFrame = originalFrame
  }
}

struct DesktopBackendState: Sendable {
  let revision: UInt64
  let windows: [DesktopWindow]
  let focusedID: UUID?
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
  var snapshot: DesktopWindow
}

// All access to records and AX handles is confined to queue. Only DTOs cross its boundary.
final class DesktopWindowBackend: @unchecked Sendable {
  let queue = DispatchQueue(label: "dev.infinitedesk.desktop-ax", qos: .userInitiated)
  private let access: any DesktopAXAccess
  private let processIdentity: @Sendable (pid_t) -> DesktopProcessIdentity?
  private var records: [UUID: DesktopWindowRecord] = [:]
  private var closedWindows: [UUID: DesktopWindow] = [:]
  private var pendingRegistrations: [UUID: DesktopOperation] = [:]
  private let observationProvider: any DesktopObservationProvider
  private let permissionCheck: @Sendable () -> Bool
  private var observers: [pid_t: DesktopObserverSession] = [:]
  private var registrationOrder: [UUID] = []
  private var trusted = true
  private var frontmostPID: pid_t?
  private var currentFocusedID: UUID?
  private var revision: UInt64 = 0
  private var lastPublishedWindows: [DesktopWindow] = []
  private var lastPublishedFocus: UUID?
  private var updateHandler: (@Sendable (DesktopBackendState) -> Void)?
  private var setupPending: [UUID] = []
  private var setupScheduled = false
  private lazy var observationInbox = DesktopObservationInbox(queue: queue) { [weak self] events in
    self?.receiveObservations(events)
  }

  init(
    access: any DesktopAXAccess = SystemDesktopAXAccess(),
    observationProvider: any DesktopObservationProvider = SystemDesktopObservationProvider(),
    permissionCheck: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
    processIdentity: @escaping @Sendable (pid_t) -> DesktopProcessIdentity? = {
      DesktopProcessIdentity.read(pid: $0)
    }
  ) {
    self.access = access
    self.observationProvider = observationProvider
    self.permissionCheck = permissionCheck
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
      windows.contains(where: { CFEqual($0, record.window) })
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
        {
          updateGeometry(id: id, frame: try frame(record.window, operation))
          if frontmostPID == record.application.pid { currentFocusedID = id }
          publish()
          return records[id]?.snapshot ?? record.snapshot
        }
      }
      Thread.sleep(forTimeInterval: 0.04)
    }
    throw DesktopWindowError.focusUnconfirmed
  }

  @discardableResult
  func commit(id: UUID, operation: DesktopOperation) throws -> DesktopWindow {
    try operation.check()
    guard let record = records[id] else {
      throw DesktopWindowError.message("This window is no longer registered.")
    }
    if pendingRegistrations[id] === operation {
      pendingRegistrations.removeValue(forKey: id)
      registrationOrder.append(id)
      scheduleObservation(id: id)
      if frontmostPID == record.application.pid { currentFocusedID = id }
      publish()
    }
    return record.snapshot
  }

  func discardPending() {
    for id in pendingRegistrations.keys { records.removeValue(forKey: id) }
    pendingRegistrations.removeAll()
  }

  func remove(id: UUID) {
    detachObservation(id: id)
    records.removeValue(forKey: id)
    closedWindows.removeValue(forKey: id)
    pendingRegistrations.removeValue(forKey: id)
    registrationOrder.removeAll { $0 == id }
    setupPending.removeAll { $0 == id }
    if currentFocusedID == id { currentFocusedID = nil }
    publish()
  }

  func removeAll() {
    for session in observers.values { session.handle.cancel() }
    observers.removeAll()
    observationInbox.clear()
    setupPending.removeAll()
    records.removeAll()
    closedWindows.removeAll()
    pendingRegistrations.removeAll()
    registrationOrder.removeAll()
    currentFocusedID = nil
    publish()
  }

}

@MainActor
final class DesktopWindowClient {
  private let backend: DesktopWindowBackend
  private var operation: DesktopOperation?
  private var timeout: DispatchWorkItem?
  private var applications: [UUID: DesktopApplicationSnapshot] = [:]
  private static let snapshotLogger = Logger(subsystem: "dev.infinitedesk.desktop", category: "snapshot")
  private var closed = false
  private(set) var windows: [DesktopWindow] = []
  private(set) var focusedID: UUID?
  var onChange: (@MainActor @Sendable () -> Void)?
  private var lastRevision: UInt64 = 0
  private var workspaceTokens: [NSObjectProtocol] = []

  var observationStatus: String? {
    guard let window = windows.first(where: {
      $0.availability != .closed && $0.observationStatus != .observing
    }) else { return nil }
    return window.observationDetail ?? "Accessibility notifications: \(window.observationStatus.rawValue)."
  }

  init(backend: DesktopWindowBackend = DesktopWindowBackend()) {
    self.backend = backend
    let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let trusted = Self.accessibilityTrusted
    backend.queue.async { [weak self] in
      backend.setUpdateHandler { [weak self] state in
        DispatchQueue.main.async { [weak self] in self?.apply(state) }
      }
      backend.setPermission(trusted)
      backend.setFrontmost(pid: pid)
    }
    let center = NSWorkspace.shared.notificationCenter
    workspaceTokens.append(center.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
      MainActor.assumeIsolated {
        guard let self, !self.closed else { return }
        let backend = self.backend
        backend.queue.async { backend.setFrontmost(pid: pid) }
      }
    })
    workspaceTokens.append(center.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
      else { return }
      MainActor.assumeIsolated {
        guard let self, !self.closed else { return }
        let backend = self.backend
        backend.queue.async { backend.processTerminated(pid: pid) }
      }
    })
  }

  private func apply(_ state: DesktopBackendState) {
    guard !closed, state.revision > lastRevision else { return }
    lastRevision = state.revision
    windows = state.windows
    focusedID = state.focusedID
    onChange?()
  }

  func setAccessibilityTrusted(_ trusted: Bool) {
    guard !closed else { return }
    if !trusted { cancel() }
    let backend = backend
    backend.queue.async { backend.setPermission(trusted) }
  }

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
    let trusted = Self.accessibilityTrusted
    setAccessibilityTrusted(trusted)
    guard trusted else {
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
            backend.queue.async { [weak self] in
              let committed = Result { try backend.commit(id: window.id, operation: operation) }
                .mapError { ($0 as? DesktopWindowError) ?? .message($0.localizedDescription) }
              DispatchQueue.main.async { [weak self] in
                guard let self, self.operation === operation else { return }
                if case .success = committed { self.applications[window.id] = application }
                self.finish(operation: operation, result: committed, completion: completion)
              }
            }
            return
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
    applications.removeValue(forKey: id)
    let backend = backend
    backend.queue.async { backend.remove(id: id) }
  }

  func close() {
    cancel()
    closed = true
    for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    workspaceTokens.removeAll()
    windows.removeAll()
    focusedID = nil
    applications.removeAll()
    onChange?()
    onChange = nil
    let backend = backend
    backend.queue.async { backend.removeAll() }
  }
}

private final class DesktopObserverSession {
  let id = UUID()
  let application: DesktopApplicationSnapshot
  let app: AXUIElement
  let handle: any DesktopAXObserverHandle
  var focusStatus = AXError.failure
  var windowIDs: Set<UUID> = []

  init(record: DesktopWindowRecord, handle: any DesktopAXObserverHandle) {
    application = record.application
    app = record.app
    self.handle = handle
  }
}

extension DesktopWindowBackend {
  func setUpdateHandler(_ handler: @escaping @Sendable (DesktopBackendState) -> Void) {
    updateHandler = handler
  }

  func state() -> DesktopBackendState {
    DesktopBackendState(
      revision: revision,
      windows: registrationOrder.compactMap { records[$0]?.snapshot ?? closedWindows[$0] },
      focusedID: currentFocusedID)
  }

  private func publish() {
    let windows = registrationOrder.compactMap { records[$0]?.snapshot ?? closedWindows[$0] }
    guard windows != lastPublishedWindows || currentFocusedID != lastPublishedFocus else { return }
    revision += 1
    lastPublishedWindows = windows
    lastPublishedFocus = currentFocusedID
    updateHandler?(DesktopBackendState(revision: revision, windows: windows, focusedID: currentFocusedID))
  }

  func setPermission(_ allowed: Bool) {
    guard trusted != allowed else { return }
    trusted = allowed
    if !allowed {
      for session in observers.values { session.handle.cancel() }
      observers.removeAll()
      observationInbox.clear()
      setupPending.removeAll()
      currentFocusedID = nil
      for id in registrationOrder where records[id] != nil {
        records[id]?.snapshot.observationStatus = .paused
        records[id]?.snapshot.observationDetail = "Accessibility permission is required."
        records[id]?.snapshot.availability = .unavailable
      }
      publish()
    } else {
      for id in registrationOrder where records[id] != nil {
        records[id]?.snapshot.observationStatus = .pending
        records[id]?.snapshot.observationDetail = nil
        scheduleObservation(id: id)
      }
      publish()
    }
  }

  func setFrontmost(pid: pid_t?) {
    setPermission(permissionCheck())
    frontmostPID = pid
    currentFocusedID = nil
    if let pid, let session = observers[pid] {
      observationInbox.submit(.init(session: session.id, windowID: nil, kind: .focus))
    }
    publish()
  }

  func processTerminated(pid: pid_t) {
    // A delayed workspace termination for an older incarnation cannot close a recycled PID's windows.
    let live = processIdentity(pid)
    let ids = registrationOrder.filter {
      guard let record = records[$0] else { return false }
      return record.application.pid == pid && record.application.processIdentity != live
    }
    for id in ids { markClosed(id: id) }
    publish()
  }

  private func scheduleObservation(id: UUID) {
    guard trusted, !setupPending.contains(id) else { return }
    setupPending.append(id)
    guard !setupScheduled else { return }
    setupScheduled = true
    queue.async { [weak self] in self?.setupNextObservation() }
  }

  private func setupNextObservation() {
    guard !setupPending.isEmpty else {
      setupScheduled = false
      return
    }
    let id = setupPending.removeFirst()
    installObservation(id: id)
    if setupPending.isEmpty {
      setupScheduled = false
    } else {
      queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in self?.setupNextObservation() }
    }
  }

  private func installObservation(id: UUID) {
    if trusted && !permissionCheck() { setPermission(false) }
    guard trusted, let record = records[id], pendingRegistrations[id] == nil,
      record.snapshot.availability != .closed
    else { return }
    guard processIdentity(record.application.pid) == record.application.processIdentity else {
      markClosed(id: id)
      publish()
      return
    }
    let operation = DesktopOperation(timeout: 1)
    do {
      let session: DesktopObserverSession
      if let existing = observers[record.application.pid],
        existing.application.processIdentity == record.application.processIdentity
      {
        session = existing
      } else {
        if let old = observers.removeValue(forKey: record.application.pid) {
          observationInbox.discard(session: old.id)
          old.handle.cancel()
        }
        let inbox = observationInbox
        let handle = try observationProvider.create(pid: record.application.pid) { event in inbox.submit(event) }
        session = DesktopObserverSession(record: record, handle: handle)
        observers[record.application.pid] = session
        try operation.check()
        session.focusStatus = handle.subscribe(
          record.app, notification: kAXFocusedWindowChangedNotification,
          event: .init(session: session.id, windowID: nil, kind: .focus))
      }
      guard !session.windowIDs.contains(id) else { return }
      session.windowIDs.insert(id)
      var statuses: [(String, AXError)] = [(kAXFocusedWindowChangedNotification, session.focusStatus)]
      for (notification, kind) in [
        (kAXMovedNotification, DesktopObservationEvent.Kind.geometry),
        (kAXResizedNotification, .geometry),
        (kAXUIElementDestroyedNotification, .destroyed),
      ] {
        try operation.check()
        let status = session.handle.subscribe(
          record.window, notification: notification,
          event: .init(session: session.id, windowID: id, kind: kind))
        statuses.append((notification, status))
      }
      try operation.check()
      let failures = statuses.filter { $0.1 != .success }
      records[id]?.snapshot.observationStatus = failures.isEmpty ? .observing
        : failures.count == statuses.count ? .unsupported : .partial
      records[id]?.snapshot.observationDetail = failures.isEmpty ? nil : "Unavailable notifications: "
        + failures.map { "\($0.0) (AX \($0.1.rawValue))" }.joined(separator: ", ")
      // One event-driven readback closes the registration/subscribe gap; there is no timer polling.
      observationInbox.submit(.init(session: session.id, windowID: id, kind: .geometry))
      observationInbox.submit(.init(session: session.id, windowID: nil, kind: .focus))
    } catch {
      if let session = observers[record.application.pid], session.windowIDs.isEmpty {
        observers.removeValue(forKey: record.application.pid)
        observationInbox.discard(session: session.id)
        session.handle.cancel()
      } else {
        detachObservation(id: id)
      }
      records[id]?.snapshot.observationStatus = .unsupported
      records[id]?.snapshot.observationDetail = error.localizedDescription
    }
    publish()
  }

  private func detachObservation(id: UUID) {
    guard let record = records[id], let session = observers[record.application.pid],
      session.windowIDs.remove(id) != nil
    else { return }
    observationInbox.discard(session: session.id, windowID: id)
    if session.windowIDs.isEmpty {
      observationInbox.discard(session: session.id)
      observers.removeValue(forKey: record.application.pid)
      session.handle.cancel()
    } else if !session.handle.unsubscribe(windowID: id) {
      // A failed unsubscribe leaves an uncertain server-side registration. Retire the observer
      // before resubscribing surviving exact handles, so stale refcons can never be reused.
      observers.removeValue(forKey: record.application.pid)
      observationInbox.discard(session: session.id)
      session.handle.cancel()
      for survivor in session.windowIDs { scheduleObservation(id: survivor) }
    }
  }

  private func markClosed(id: UUID) {
    guard var snapshot = records[id]?.snapshot else { return }
    detachObservation(id: id)
    records.removeValue(forKey: id)
    pendingRegistrations.removeValue(forKey: id)
    snapshot.availability = .closed
    snapshot.observationStatus = .paused
    snapshot.observationDetail = "The registered window closed."
    closedWindows[id] = snapshot
    setupPending.removeAll { $0 == id }
    if currentFocusedID == id { currentFocusedID = nil }
  }

  private func updateGeometry(id: UUID, frame: CGRect) {
    guard records[id]?.snapshot.availability != .closed else { return }
    records[id]?.snapshot.worldFrame = frame
    records[id]?.snapshot.availability = .available
  }

  private func refreshGeometry(id: UUID, operation: DesktopOperation) -> Bool {
    guard let record = records[id] else { return true }
    do {
      try validateProcess(record.application, operation)
      guard access.pid(record.window) == record.application.pid,
        try read(record.window, kAXRoleAttribute, operation) as? String == kAXWindowRole
      else { throw DesktopWindowError.message("The registered window is temporarily inaccessible.") }
      let current = try frame(record.window, operation)
      try validateProcess(record.application, operation)
      updateGeometry(id: id, frame: current)
      return true
    } catch {
      if processIdentity(record.application.pid) != record.application.processIdentity {
        markClosed(id: id)
        return true
      }
      records[id]?.snapshot.availability = .unavailable
      return false
    }
  }

  private func refreshFocus(_ session: DesktopObserverSession, operation: DesktopOperation) -> Bool {
    guard frontmostPID == session.application.pid else { return true }
    currentFocusedID = nil
    do {
      try validateProcess(session.application, operation)
      guard let focused = try read(session.app, kAXFocusedWindowAttribute, operation),
        CFGetTypeID(focused) == AXUIElementGetTypeID()
      else { return false }
      currentFocusedID = session.windowIDs.first { id in
        guard let record = records[id], record.snapshot.availability != .closed else { return false }
        return CFEqual(record.window, focused)
      }
      return true
    } catch { return false }
  }

  private func receiveObservations(_ events: [DesktopObservationEvent]) {
    guard trusted else { return }
    guard permissionCheck() else {
      setPermission(false)
      return
    }
    for event in events {
      guard let session = observers.values.first(where: { $0.id == event.session }) else { continue }
      guard processIdentity(session.application.pid) == session.application.processIdentity else {
        for id in Array(session.windowIDs) { markClosed(id: id) }
        continue
      }
      if event.kind == .destroyed, let id = event.windowID, session.windowIDs.contains(id) {
        markClosed(id: id)
        continue
      }
      let operation = DesktopOperation(timeout: 0.8)
      switch event.kind {
      case .focus, .focusRetry:
        if !refreshFocus(session, operation: operation), event.kind == .focus {
          observationInbox.submit(.init(session: session.id, windowID: nil, kind: .focusRetry))
        }
      case .geometry, .geometryRetry:
        if let id = event.windowID, session.windowIDs.contains(id),
          !refreshGeometry(id: id, operation: operation), event.kind == .geometry
        {
          observationInbox.submit(.init(session: session.id, windowID: id, kind: .geometryRetry))
        }
      case .destroyed: break
      }
    }
    publish()
  }
}
