import AppKit
@preconcurrency import ApplicationServices
import Darwin
import Foundation
import OSLog

struct DesktopProcessIdentity: Codable, Equatable, Sendable {
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
  var cameraPage = 0
  var managerMinimized = false
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
  var camera = DesktopCameraSnapshot()
}

func desktopLaunchDatesCompatible(expected: Date?, actual: Date?) -> Bool {
  guard let expected, let actual else { return true }
  return expected == actual
}

enum DesktopWindowError: LocalizedError, Sendable {
  case message(String)
  case focusUnconfirmed
  case cameraInputCoalesced

  var errorDescription: String? {
    switch self {
    case .message(let text): return text
    case .cameraInputCoalesced: return "Camera input was coalesced into a newer packet."
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

// Registration and focus never call the camera mutation interface.
protocol DesktopAXAccess: AnyObject {
  func application(pid: pid_t) -> AXUIElement
  func timeout(_ element: AXUIElement) -> Bool
  func read(_ element: AXUIElement, _ name: String) -> CFTypeRef?
  func pid(_ element: AXUIElement) -> pid_t?
  func perform(_ element: AXUIElement, _ action: String) -> AXError
  func mainSettable(_ element: AXUIElement) -> Bool
  func makeMain(_ element: AXUIElement) -> AXError
}

protocol DesktopCameraAXAccess: DesktopAXAccess {
  func settable(_ element: AXUIElement, _ name: String) -> Bool
  func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> AXError
}

final class SystemDesktopAXAccess: DesktopCameraAXAccess {
  func settable(_ element: AXUIElement, _ name: String) -> Bool {
    var result = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
  }
  func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> AXError {
    AXUIElementSetAttributeValue(element, name as CFString, value)
  }
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
  var lastPhysicalFrame: CGRect?
  var cameraScopeEligible = false
  var positionManaged = false
  var intendedPhysicalFrame: CGRect?
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
  private var camera = DesktopCameraSnapshot()
  private var cameraDisplay: DesktopCameraDisplay?
  private var cameraJournal: DesktopCameraJournal?
  private var cameraJournalLoaded = false
  private var cameraScopeInvalid = false
  private var continuousCamera = false
  private let onCurrentSpace: @Sendable (pid_t, CGRect) -> Bool
  private let applicationIsActive: @Sendable (pid_t) -> Bool
  private let userInputGeneration: @Sendable () -> UInt64
  private var lastPublishedCamera = DesktopCameraSnapshot()
  private var pageFocus: [Int: UUID] = [:]
  private static let cameraLogger = Logger(subsystem: "dev.infinitedesk.desktop", category: "camera")
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
    cameraJournal: DesktopCameraJournal? = nil,
    onCurrentSpace: @escaping @Sendable (pid_t, CGRect) -> Bool = { desktopWindowOnCurrentSpace(pid: $0, frame: $1) },
    applicationIsActive: @escaping @Sendable (pid_t) -> Bool = {
      NSRunningApplication(processIdentifier: $0)?.isActive == true
    },
    userInputGeneration: @escaping @Sendable () -> UInt64 = {
      [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown].reduce(UInt64(0)) {
        $0 &+ UInt64(CGEventSource.counterForEventType(.combinedSessionState, eventType: $1))
      }
    },
    processIdentity: @escaping @Sendable (pid_t) -> DesktopProcessIdentity? = {
      DesktopProcessIdentity.read(pid: $0)
    }
  ) {
    self.access = access
    self.cameraJournal = cameraJournal
    self.onCurrentSpace = onCurrentSpace
    self.applicationIsActive = applicationIsActive
    self.userInputGeneration = userInputGeneration
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
      if frontmostPID == application.pid, onCurrentSpace(application.pid, try frame(window, operation)) {
        records[existing.snapshot.id]?.cameraScopeEligible = true
      }
      return existing.snapshot
    }
    let title = try read(window, kAXTitleAttribute, operation) as? String ?? ""
    var snapshot = DesktopWindow(
      id: UUID(), pid: application.pid, appName: application.appName,
      title: title.isEmpty ? "Untitled window" : title,
      originalFrame: try frame(window, operation), launchDate: application.launchDate,
      processIdentity: application.processIdentity)
    guard let focused = try read(app, kAXFocusedWindowAttribute, operation), CFEqual(focused, window)
    else { throw DesktopWindowError.message("Focus changed during registration. Retry with the intended window.") }
    try validateProcess(application, operation)
    try operation.check()
    snapshot.cameraPage = camera.page
    snapshot.worldFrame = snapshot.originalFrame.offsetBy(dx: camera.origin.x, dy: camera.origin.y)
    records[snapshot.id] = DesktopWindowRecord(
      application: application, app: app, window: window, snapshot: snapshot,
      lastPhysicalFrame: snapshot.originalFrame,
      cameraScopeEligible: frontmostPID == application.pid && onCurrentSpace(application.pid, snapshot.originalFrame))
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

  @discardableResult
  func remove(id: UUID) -> Bool {
    if records[id]?.snapshot.managerMinimized == true || records[id]?.positionManaged == true {
      do { try restoreManagedWindow(id: id, operation: DesktopOperation()) }
      catch {
        camera.detail = "Cannot forget a parked window: \(error.localizedDescription)"
        publish()
        return false
      }
    }
    detachObservation(id: id)
    records.removeValue(forKey: id)
    closedWindows.removeValue(forKey: id)
    pendingRegistrations.removeValue(forKey: id)
    registrationOrder.removeAll { $0 == id }
    setupPending.removeAll { $0 == id }
    if currentFocusedID == id { currentFocusedID = nil }
    publish()
    return true
  }

  func removeAll() {
    for id in registrationOrder where records[id]?.snapshot.managerMinimized == true || records[id]?.positionManaged == true {
      do { try restoreManagedWindow(id: id, operation: DesktopOperation()) }
      catch {
        camera.paused = true
        camera.detail = "Shutdown recovery retained: \(error.localizedDescription)"
      }
    }
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
  private let displayProvider: @MainActor @Sendable () -> DesktopCameraDisplay?
  private var operation: DesktopOperation?
  private var timeout: DispatchWorkItem?
  private var applications: [UUID: DesktopApplicationSnapshot] = [:]
  private static let snapshotLogger = Logger(subsystem: "dev.infinitedesk.desktop", category: "snapshot")
  private var closed = false
  private(set) var windows: [DesktopWindow] = []
  private(set) var focusedID: UUID?
  private(set) var camera = DesktopCameraSnapshot()
  private(set) var isCameraBusy = false
  private(set) var panMetrics: DesktopPanMetrics? = {
    let environment = ProcessInfo.processInfo.environment
    return environment["INFINITEDESK_TEST_STATE_PATH"] != nil || environment["INFINITEDESK_PAN_METRICS"] == "1" ? DesktopPanMetrics() : nil
  }()
  var onChange: (@MainActor @Sendable () -> Void)?
  private var lastRevision: UInt64 = 0
  private var workspaceTokens: [NSObjectProtocol] = []
  private var screenToken: NSObjectProtocol?
  private var cameraOperation: DesktopOperation?
  private var queuedCameraMove: (delta: Int, completion: @MainActor @Sendable (Result<DesktopCameraSnapshot, DesktopWindowError>) -> Void)?
  private var queuedPan: (delta: CGFloat, ended: Bool, completion: @MainActor @Sendable (Result<DesktopCameraSnapshot, DesktopWindowError>) -> Void)?
  private var queuedPause: (@MainActor @Sendable (Result<DesktopCameraSnapshot, DesktopWindowError>) -> Void)?
  private var queuedQuit: (@MainActor @Sendable (Result<DesktopCameraSnapshot, DesktopWindowError>) -> Void)?
  var recoveryInstructions: String { camera.recoveryInstructions ?? camera.detail ?? "No interrupted window changes require recovery." }

  var observationStatus: String? {
    guard let window = windows.first(where: {
      $0.availability != .closed && $0.observationStatus != .observing
    }) else { return nil }
    return window.observationDetail ?? "Accessibility notifications: \(window.observationStatus.rawValue)."
  }

  init(
    backend: DesktopWindowBackend = DesktopWindowBackend(),
    displayProvider: @escaping @MainActor @Sendable () -> DesktopCameraDisplay? = { DesktopCameraDisplay.current() }
  ) {
    self.backend = backend
    self.displayProvider = displayProvider
    let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let trusted = Self.accessibilityTrusted
    backend.queue.async { [weak self] in
      backend.setUpdateHandler { [weak self] state in
        DispatchQueue.main.async { [weak self] in self?.apply(state) }
      }
      backend.setPermission(trusted)
      backend.setFrontmost(pid: pid)
      backend.loadCameraRecovery()
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
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.closed else { return }
        self.invalidateCameraScope()
      }
    })
    screenToken = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.invalidateCameraScope() }
    }
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
    camera = state.camera
    onChange?()
  }

  private func invalidateCameraScope() {
    guard !closed else { return }
    cameraOperation?.cancel()
    operation?.cancel()
    let backend = backend
    backend.queue.async { backend.invalidateCameraScope() }
  }

  func setAccessibilityTrusted(_ trusted: Bool) {
    guard !closed else { return }
    if !trusted {
      cameraOperation?.cancel()
      cancel()
    }
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
    cameraOwned: Bool = false,
    completion: @escaping @MainActor @Sendable (Result<DesktopWindow, DesktopWindowError>) -> Void
  ) -> DesktopOperation? {
    guard !isCameraBusy || cameraOwned else {
      completion(.failure(.message("Wait for the current camera operation to finish.")))
      return nil
    }
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
    id: UUID, cameraOwned: Bool = false,
    completion: @escaping @MainActor @Sendable (Result<DesktopWindow, DesktopWindowError>) -> Void
  ) {
    guard let operation = begin(cameraOwned: cameraOwned, completion: completion) else { return }
    guard let application = applications[id],
      let app = liveApplication(application), windows.contains(where: { $0.id == id })
    else {
      finish(operation: operation, result: .failure(.message("The registered application exited. Register its window again.")), completion: completion)
      return
    }
    let backend = backend
    let display = displayProvider()
    backend.queue.async { [weak self] in
      do {
        try backend.reveal(id: id, display: display, operation: operation)
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
    let backend = backend
    backend.queue.async { [weak self] in
      let removed = backend.remove(id: id)
      if removed { DispatchQueue.main.async { [weak self] in self?.applications.removeValue(forKey: id) } }
    }
  }

  func close() {
    cancel()
    closed = true
    for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    workspaceTokens.removeAll()
    if let screenToken { NotificationCenter.default.removeObserver(screenToken) }
    screenToken = nil
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
      focusedID: currentFocusedID, camera: camera)
  }

  private func publish() {
    camera.requiresRestoration = records.values.contains { $0.snapshot.managerMinimized || $0.positionManaged }
    let windows = registrationOrder.compactMap { records[$0]?.snapshot ?? closedWindows[$0] }
    guard windows != lastPublishedWindows || currentFocusedID != lastPublishedFocus || camera != lastPublishedCamera else { return }
    revision += 1
    lastPublishedWindows = windows
    lastPublishedFocus = currentFocusedID
    lastPublishedCamera = camera
    updateHandler?(DesktopBackendState(revision: revision, windows: windows, focusedID: currentFocusedID, camera: camera))
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
    if snapshot.managerMinimized || cameraJournal?.entries.contains(where: { $0.id == id }) == true {
      do { try cameraJournal?.complete(id: id) }
      catch {
        camera.recoveryCount = cameraJournal?.entries.count ?? 1
        camera.recoveryInstructions = DesktopCameraRecovery.inspect(cameraJournal?.entries ?? [], processIdentity: processIdentity).map(\.instructions).joined(separator: "\n\n")
        camera.detail = "A closed window's recovery entry could not be cleared: \(error.localizedDescription)"
        camera.paused = true
      }
    }
    snapshot.managerMinimized = false
    snapshot.availability = .closed
    snapshot.observationStatus = .paused
    snapshot.observationDetail = "The registered window closed."
    closedWindows[id] = snapshot
    setupPending.removeAll { $0 == id }
    if currentFocusedID == id { currentFocusedID = nil }
  }

  private func updateGeometry(id: UUID, frame: CGRect) {
    guard let record = records[id], record.snapshot.availability != .closed,
      !record.snapshot.managerMinimized else { return }
    if let previous = record.lastPhysicalFrame, desktopFramesEqual(previous, frame, tolerance: 0.01) {
      records[id]?.snapshot.availability = .available
      return
    }
    if continuousCamera, camera.paused {
      if !record.positionManaged, let previous = record.lastPhysicalFrame {
        records[id]?.snapshot.worldFrame = record.snapshot.worldFrame.offsetBy(dx: frame.minX - previous.minX, dy: frame.minY - previous.minY)
        records[id]?.snapshot.worldFrame.size = frame.size
        records[id]?.lastPhysicalFrame = frame
      }
      return
    }
    if record.positionManaged {
      if let intended = record.intendedPhysicalFrame, desktopFramesEqual(intended, frame, tolerance: 0.01) {
        records[id]?.lastPhysicalFrame = frame
        records[id]?.snapshot.availability = .available
        return
      }
    }
    if record.positionManaged {
      do { try cameraJournal?.checkpointRestorable(id: id, frame: frame, minimized: false) }
      catch {
        camera.paused = true
        camera.detail = "Camera paused while saving the moved window: \(error.localizedDescription)"
        return
      }
    }
    records[id]?.lastPhysicalFrame = frame
    // Pause releases physical positions while retaining the virtual layout.
    guard !continuousCamera || !camera.paused else { return }
    let origin = continuousCamera ? camera.origin
      : (cameraDisplay?.origin(page: record.snapshot.cameraPage) ?? camera.origin)
    records[id]?.snapshot.worldFrame = frame.offsetBy(dx: origin.x, dy: origin.y)
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
      if let id = currentFocusedID, let record = records[id], record.snapshot.managerMinimized,
        try read(record.window, kAXMinimizedAttribute, operation) as? Bool == false
      {
        let physical = try frame(record.window, operation)
        if onCurrentSpace(record.application.pid, physical) {
          if !record.positionManaged { try cameraJournal?.complete(id: id) }
          records[id]?.snapshot.managerMinimized = false
          records[id]?.snapshot.cameraPage = camera.page
          records[id]?.lastPhysicalFrame = nil
          records[id]?.intendedPhysicalFrame = nil
          updateGeometry(id: id, frame: physical)
        }
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

extension DesktopWindowBackend {
  func loadCameraRecovery() {
    guard !cameraJournalLoaded else { return }
    cameraJournalLoaded = true
    do {
      if cameraJournal == nil { cameraJournal = try DesktopCameraJournal() }
      camera.recoveryCount = cameraJournal?.entries.count ?? 0
      if camera.recoveryCount > 0 {
        camera.recoveryInstructions = DesktopCameraRecovery.inspect(cameraJournal?.entries ?? [], processIdentity: processIdentity)
          .map(\.instructions).joined(separator: "\n\n")
        camera.paused = true
        camera.detail = "Recovery is required for \(camera.recoveryCount) previously managed window(s)."
      }
    } catch {
      camera.paused = true
      camera.detail = "Recovery journal unavailable: \(error.localizedDescription)"
      camera.recoveryCount = 1
    }
    publish()
  }

  private func refreshPendingRecovery() {
    let unresolved = (cameraJournal?.entries ?? []).filter { records[$0.id]?.snapshot.managerMinimized != true && records[$0.id]?.positionManaged != true }
    camera.recoveryCount = unresolved.count
    camera.recoveryInstructions = unresolved.isEmpty ? nil : DesktopCameraRecovery.inspect(unresolved, processIdentity: processIdentity)
      .map(\.instructions).joined(separator: "\n\n")
  }

  private func reconcileCameraJournal(operation: DesktopOperation) throws {
    guard let journal = cameraJournal else { return }
    for entry in journal.entries where records[entry.id]?.snapshot.managerMinimized != true && records[entry.id]?.positionManaged != true {
      guard let record = records[entry.id], record.application.pid == entry.pid,
        record.application.processIdentity == entry.processIdentity else { continue }
      let minimized = try validateCameraIdentity(record, operation)
      guard !minimized, desktopFramesEqual(try frame(record.window, operation), entry.originalFrame) else { continue }
      // This exact session handle confirms that write-ahead intent never changed the original.
      try journal.complete(id: entry.id)
    }
    refreshPendingRecovery()
  }

  func invalidateCameraScope() {
    for id in registrationOrder { records[id]?.cameraScopeEligible = false }
    guard cameraDisplay != nil else { return }
    cameraScopeInvalid = true
    camera.paused = true
    camera.detail = "Display or Space changed. Return to the original display and Space, then restore windows."
    publish()
  }

  private func validateCameraIdentity(_ record: DesktopWindowRecord, _ operation: DesktopOperation) throws -> Bool {
    try validateProcess(record.application, operation)
    guard access.pid(record.window) == record.application.pid else {
      throw DesktopWindowError.message("The exact AX handle returned a different or unavailable PID.")
    }
    guard try read(record.window, kAXRoleAttribute, operation) as? String == kAXWindowRole else {
      throw DesktopWindowError.message("AXRole is unavailable or is not AXWindow.")
    }
    guard try read(record.window, kAXSubroleAttribute, operation) as? String == kAXStandardWindowSubrole else {
      throw DesktopWindowError.message("AXSubrole is unavailable or is not AXStandardWindow.")
    }
    guard try read(record.window, "AXFullScreen", operation) as? Bool == false else {
      throw DesktopWindowError.message("AXFullScreen is unavailable or true.")
    }
    guard let minimized = try read(record.window, kAXMinimizedAttribute, operation) as? Bool else {
      throw DesktopWindowError.message("AXMinimized is temporarily unavailable.")
    }
    guard let windows = try read(record.app, kAXWindowsAttribute, operation) as? [AXUIElement],
      windows.contains(where: { CFEqual($0, record.window) }) else {
      throw DesktopWindowError.message("AXWindows is unavailable or does not yet contain the exact registered handle.")
    }
    if let sheets = try read(record.window, "AXSheets", operation) as? [AXUIElement], !sheets.isEmpty {
      throw DesktopWindowError.message("A window with an attached dialog cannot change pages.")
    }
    try validateProcess(record.application, operation)
    return minimized
  }

  private func ensureCamera(display: DesktopCameraDisplay?, operation: DesktopOperation) throws -> DesktopCameraDisplay {
    try operation.check()
    loadCameraRecovery()
    guard permissionCheck(), trusted else { throw DesktopWindowError.message("Accessibility permission is required.") }
    guard camera.recoveryCount == 0 else { throw DesktopWindowError.message(camera.detail ?? "Resolve saved recovery entries before moving the camera.") }
    guard let display, display.frame.width.isFinite, display.frame.width > 0 else {
      throw DesktopWindowError.message("The camera currently supports exactly one display.")
    }
    if let previous = cameraDisplay, previous != display {
      for id in registrationOrder { records[id]?.cameraScopeEligible = false }
      cameraScopeInvalid = true
    }
    guard !cameraScopeInvalid else { throw DesktopWindowError.message("Display or Space changed. Restore managed windows before resuming.") }
    cameraDisplay = display
    return display
  }

  private func cameraCandidates(operation: DesktopOperation) throws -> [UUID] {
    guard let writer = access as? any DesktopCameraAXAccess else {
      throw DesktopWindowError.message("This Accessibility adapter does not support camera mutations.")
    }
    var ids: [UUID] = []
    for id in registrationOrder {
      guard let record = records[id] else { continue }
      guard record.cameraScopeEligible else {
        records[id]?.snapshot.availability = .unavailable
        records[id]?.snapshot.observationDetail = "This window was not registered in the current desktop scope. Register it again."
        continue
      }
      do {
        let minimized = try validateCameraIdentity(record, operation)
        if record.snapshot.managerMinimized {
          if !minimized {
            // A Dock click or external deminiaturization is an explicit user takeover.
            let physical = try frame(record.window, operation)
            guard onCurrentSpace(record.application.pid, physical) else { continue }
            if !record.positionManaged { try cameraJournal?.complete(id: id) }
            records[id]?.snapshot.managerMinimized = false
            records[id]?.snapshot.cameraPage = camera.page
            records[id]?.lastPhysicalFrame = nil
            records[id]?.intendedPhysicalFrame = nil
            updateGeometry(id: id, frame: physical)
          }
        } else {
          guard !minimized else { continue }
          let physical = try frame(record.window, operation)
          guard record.positionManaged || onCurrentSpace(record.application.pid, physical) else { continue }
          updateGeometry(id: id, frame: physical)
        }
      } catch {
        if record.snapshot.managerMinimized { throw error }
        records[id]?.snapshot.availability = .unavailable
        records[id]?.snapshot.observationDetail = error.localizedDescription
        continue
      }
      guard writer.settable(record.window, kAXMinimizedAttribute) else {
        throw DesktopWindowError.message("\(record.snapshot.appName) does not allow reliable minimization.")
      }
      ids.append(id)
    }
    return ids
  }

  private func confirmCameraMutation(
    _ record: DesktopWindowRecord, minimized: Bool, restoredFrame: CGRect?, operation: DesktopOperation
  ) throws {
    let deadline = DispatchTime.now() + .seconds(2)
    var lastFailure = "The application has not reported the requested minimized state."
    var attempts = 0
    repeat {
      try operation.check()
      // Process replacement is terminal; temporary AX failures during Dock animation are not.
      try validateProcess(record.application, operation)
      attempts += 1
      do {
        let actual = try validateCameraIdentity(record, operation)
        if actual == minimized {
          if let restoredFrame {
            let physical = try frame(record.window, operation)
            if desktopFramesEqual(physical, restoredFrame) { return }
            lastFailure = "Restored bounds are \(physical); expected \(restoredFrame)."
          } else { return }
        } else { lastFailure = "AXMinimized is \(actual); expected \(minimized)." }
      } catch {
        try operation.check()
        try validateProcess(record.application, operation)
        lastFailure = error.localizedDescription
      }
      if DispatchTime.now() >= deadline { break }
      Thread.sleep(forTimeInterval: 0.05)
    } while DispatchTime.now() < deadline
    throw DesktopWindowError.message("Readback did not converge within two seconds (\(attempts) attempts): \(lastFailure)")
  }

  private func setManagerMinimized(id: UUID, minimized: Bool, operation: DesktopOperation) throws {
    guard let record = records[id], let writer = access as? any DesktopCameraAXAccess,
      let journal = cameraJournal else { throw DesktopWindowError.message("The recovery journal is unavailable.") }
    if !minimized && !record.snapshot.managerMinimized { return }
    var phase = "preflight"
    do {
      let actual = try validateCameraIdentity(record, operation)
      phase = "frame-before-write"
      let physical = try frame(record.window, operation)
      if minimized {
        guard !actual, onCurrentSpace(record.application.pid, physical) else {
          if actual && record.snapshot.managerMinimized { return }
          throw DesktopWindowError.message("The window is minimized by its owner or outside the current Space.")
        }
        phase = "journal-prepare"
        if !record.positionManaged { try journal.prepare(DesktopCameraJournalEntry(
          id: id, pid: record.application.pid, processIdentity: record.application.processIdentity,
          title: record.snapshot.title, appName: record.snapshot.appName,
          bundleIdentifier: record.application.bundleIdentifier, originalFrame: physical)) }
        records[id]?.lastPhysicalFrame = physical
      }
      let target = records[id]?.lastPhysicalFrame ?? physical
      if actual != minimized {
        phase = "journal-intent"
        try journal.recordIntent(id: id, frame: target, minimized: minimized)
        phase = "identity-before-write"
        guard try validateCameraIdentity(record, operation) == actual else {
          throw DesktopWindowError.message("The user changed the window's minimized state during the camera operation.")
        }
        try operation.check()
        // Mark ownership before IPC: a failed reply can still mean the write was delivered.
        if minimized { records[id]?.snapshot.managerMinimized = true }
        phase = "write-minimized"
        let status = writer.set(record.window, kAXMinimizedAttribute, minimized ? kCFBooleanTrue : kCFBooleanFalse)
        try operation.check()
        guard status == .success || status == .cannotComplete else {
          throw DesktopWindowError.message("The application refused minimization (AX \(status.rawValue)).")
        }
        phase = "confirm-minimized"
        try confirmCameraMutation(record, minimized: minimized, restoredFrame: minimized || record.positionManaged ? nil : target, operation: operation)
      }
      if !minimized {
        phase = "confirm-restored-frame"
        try confirmCameraMutation(record, minimized: false, restoredFrame: record.positionManaged ? nil : target, operation: operation)
        phase = "journal-complete"
        do { if !record.positionManaged { try journal.complete(id: id) } }
        catch {
          records[id]?.snapshot.managerMinimized = false
          refreshPendingRecovery()
          throw error
        }
        records[id]?.snapshot.managerMinimized = false
        records[id]?.snapshot.availability = .available
      }
      if currentFocusedID == id && minimized { currentFocusedID = nil }
    } catch {
      let action = minimized ? "park" : "restore"
      Self.cameraLogger.error("camera mutation failed action=\(action, privacy: .public) phase=\(phase, privacy: .public) id=\(id.uuidString, privacy: .public) pid=\(record.application.pid) reason=\(error.localizedDescription, privacy: .public)")
      throw DesktopWindowError.message("Camera \(action) failed during \(phase): \(error.localizedDescription)")
    }
  }

  private func savePositionOwnership(id: UUID, physicalFrame: CGRect?, operation: DesktopOperation) throws {
    guard let record = records[id], !record.positionManaged else { return }
    guard let journal = cameraJournal else { throw DesktopWindowError.message("The recovery journal is unavailable.") }
    let physical = try physicalFrame ?? frame(record.window, operation)
    try journal.preparePosition(DesktopCameraJournalEntry(
      id: id, pid: record.application.pid, processIdentity: record.application.processIdentity,
      title: record.snapshot.title, appName: record.snapshot.appName,
      bundleIdentifier: record.application.bundleIdentifier, originalFrame: physical))
    records[id]?.positionManaged = true
    records[id]?.lastPhysicalFrame = physical
  }

  private func writePosition(id: UUID, target: CGRect, operation: DesktopOperation) throws -> CGRect {
    guard let record = records[id], let writer = access as? any DesktopCameraAXAccess,
      writer.settable(record.window, kAXPositionAttribute) else {
      throw DesktopWindowError.message("This window does not allow native position changes.")
    }
    _ = try validateCameraIdentity(record, operation)
    try operation.check()
    var point = target.origin
    guard let value = AXValueCreate(.cgPoint, &point) else {
      throw DesktopWindowError.message("Cannot encode the native window position.")
    }
    records[id]?.intendedPhysicalFrame = target
    let status = writer.set(record.window, kAXPositionAttribute, value)
    try operation.check()
    guard status == .success || status == .cannotComplete else {
      throw DesktopWindowError.message("The application refused the native position (AX \(status.rawValue)).")
    }
    let physical = try frame(record.window, operation)
    records[id]?.lastPhysicalFrame = physical
    if status == .cannotComplete, !desktopFramesEqual(physical, target) {
      throw DesktopWindowError.message("The native position reply was uncertain and readback did not confirm it.")
    }
    return physical
  }

  private func restoreManagedWindow(id: UUID, operation: DesktopOperation) throws {
    guard let record = records[id] else { return }
    if record.snapshot.managerMinimized {
      try setManagerMinimized(id: id, minimized: false, operation: operation)
    }
    guard record.positionManaged, let journal = cameraJournal,
      let entry = journal.entries.first(where: { $0.id == id }) else { return }
    guard try validateCameraIdentity(record, operation) == false else {
      throw DesktopWindowError.message("A user-minimized window requires manual restoration.")
    }
    let current = try frame(record.window, operation)
    if !desktopFramesEqual(current, entry.restorationFrame) {
      let actual = try writePosition(id: id, target: entry.restorationFrame, operation: operation)
      guard desktopFramesEqual(actual, entry.restorationFrame) else {
        throw DesktopWindowError.message("macOS constrained the recovery position; restore this window manually.")
      }
    }
    records[id]?.lastPhysicalFrame = try frame(record.window, operation)
    try journal.complete(id: id)
    records[id]?.positionManaged = false
    records[id]?.intendedPhysicalFrame = nil
    records[id]?.snapshot.managerMinimized = false
    records[id]?.snapshot.availability = .available
  }

  func panCamera(by delta: CGFloat, ended: Bool = false, display: DesktopCameraDisplay?, operation: DesktopOperation) throws -> DesktopCameraSnapshot {
    let display = try ensureCamera(display: display, operation: operation)
    guard !camera.paused else { throw DesktopWindowError.message("Resume the camera before panning.") }
    let target = camera.origin.x + delta
    guard delta.isFinite, target.isFinite, abs(target / display.frame.width) <= 100_000 else {
      throw DesktopWindowError.message("The requested camera position is outside the supported range.")
    }
    if delta == 0 {
      camera.focusTargetID = nil
      if ended { _ = try cameraCandidates(operation: operation); publish() }
      return camera
    }
    continuousCamera = true
    return try applyContinuousCamera(origin: target, display: display, operation: operation)
  }

  private struct UnparkFocus {
    let previousID: UUID
    let arrivingID: UUID
    let inputGeneration: UInt64
  }

  private func focusBeforeUnpark(
    id: UUID, origin: CGFloat, display: DesktopCameraDisplay, operation: DesktopOperation
  ) throws -> UnparkFocus? {
    let generation = userInputGeneration()
    guard let arriving = records[id], arriving.snapshot.managerMinimized,
      frontmostPID == arriving.application.pid, applicationIsActive(arriving.application.pid),
      let focused = try read(arriving.app, kAXFocusedWindowAttribute, operation)
    else { return nil }
    guard let previousID = registrationOrder.first(where: { candidate in
      guard candidate != id, let previous = records[candidate],
        previous.application.pid == arriving.application.pid,
        previous.application.processIdentity == arriving.application.processIdentity,
        previous.cameraScopeEligible, !previous.snapshot.managerMinimized,
        let physical = previous.lastPhysicalFrame, physical.intersects(display.frame),
        previous.snapshot.worldFrame.offsetBy(dx: -origin, dy: 0).intersects(display.frame)
      else { return false }
      return CFEqual(previous.window, focused)
    }) else { return nil }
    guard userInputGeneration() == generation else { return nil }
    return UnparkFocus(previousID: previousID, arrivingID: id, inputGeneration: generation)
  }

  private func preserveUnparkFocus(_ saved: UnparkFocus?, operation: DesktopOperation) throws {
    guard let saved, let previous = records[saved.previousID], let arriving = records[saved.arrivingID] else { return }
    func stillOwned() throws -> Bool {
      guard frontmostPID == previous.application.pid, applicationIsActive(previous.application.pid),
        userInputGeneration() == saved.inputGeneration,
        let focused = try read(previous.app, kAXFocusedWindowAttribute, operation)
      else { return false }
      return CFEqual(focused, arriving.window)
    }
    guard try stillOwned(), try validateCameraIdentity(previous, operation) == false,
      try stillOwned() else { return }
    // Deminiaturization can focus its own arrival. Restore only the exact displaced sibling;
    // never activate a process or follow a subsequent user/application focus change.
    let status = access.perform(previous.window, kAXRaiseAction)
    try operation.check()
    guard status == .success || status == .cannotComplete else {
      throw DesktopWindowError.message("Could not preserve the focused window after native restoration.")
    }
    if let focused = try read(previous.app, kAXFocusedWindowAttribute, operation), CFEqual(focused, previous.window) {
      currentFocusedID = saved.previousID
      return
    }
    guard try stillOwned() else { return }
    guard access.mainSettable(previous.window) else {
      throw DesktopWindowError.message("The displaced sibling does not allow restoring native Main focus.")
    }
    guard try stillOwned() else { return }
    let mainStatus = access.makeMain(previous.window)
    try operation.check()
    guard mainStatus == .success || mainStatus == .cannotComplete else {
      throw DesktopWindowError.message("Could not restore Main to the selected sibling after native restoration.")
    }
    if let focused = try read(previous.app, kAXFocusedWindowAttribute, operation), CFEqual(focused, previous.window) {
      currentFocusedID = saved.previousID
    } else if try stillOwned() {
      throw DesktopWindowError.message("Native restoration displaced keyboard focus and the selected sibling could not regain it.")
    }
  }

  private func applyContinuousCamera(
    origin: CGFloat, display: DesktopCameraDisplay, operation: DesktopOperation, focusArrival: Bool = false
  ) throws -> DesktopCameraSnapshot {
    do {
      let ids = try cameraCandidates(operation: operation)
      guard !camera.paused else { throw DesktopWindowError.message(camera.detail ?? "Camera restoration is required.") }
      if let currentFocusedID, let focused = records[currentFocusedID] {
        pageFocus[focused.snapshot.cameraPage] = currentFocusedID
      }
      var constrained = false
      // Every mutation is performed on this queue. Save originals before the first position IPC.
      for id in ids {
        guard let record = records[id] else { continue }
        let target = record.snapshot.worldFrame.offsetBy(dx: -origin, dy: 0)
        let visible = target.maxX > display.frame.minX && target.minX < display.frame.maxX
        if !visible {
          if !record.snapshot.managerMinimized { try setManagerMinimized(id: id, minimized: true, operation: operation) }
          continue
        }
        // Candidates already validated scope/identity and sampled each visible frame on this queue.
        // A parked arrival needs a fresh frame after its deminiaturization instead.
        let sampledFrame = record.snapshot.managerMinimized ? nil : record.lastPhysicalFrame
        try savePositionOwnership(id: id, physicalFrame: sampledFrame, operation: operation)
        if record.snapshot.managerMinimized {
          let savedFocus = try focusBeforeUnpark(id: id, origin: origin, display: display, operation: operation)
          try setManagerMinimized(id: id, minimized: false, operation: operation)
          try preserveUnparkFocus(savedFocus, operation: operation)
        }
        let current = try sampledFrame ?? frame(record.window, operation)
        if !desktopFramesEqual(current, target, tolerance: 0.01) {
          let physical = try writePosition(id: id, target: target, operation: operation)
          constrained = constrained || !desktopFramesEqual(physical, target)
        }
        records[id]?.snapshot.availability = .available
      }
      camera.origin = CGPoint(x: origin, y: 0)
      camera.page = Int(floor(origin / display.frame.width))
      camera.focusTargetID = nil
      if focusArrival {
        let arrivals = ids.filter { records[$0]?.snapshot.managerMinimized == false }
        camera.focusTargetID = pageFocus[camera.page].flatMap { arrivals.contains($0) ? $0 : nil } ?? arrivals.first
      }
      camera.detail = constrained ? "macOS constrained a partially visible window at the display edge." : nil
      publish()
      return camera
    } catch {
      refreshPendingRecovery()
      camera.paused = true
      camera.detail = "Camera paused: \(error.localizedDescription) Use Restore to release managed windows."
      publish()
      throw error
    }
  }

  func moveCamera(by delta: Int, display: DesktopCameraDisplay?, operation: DesktopOperation) throws -> DesktopCameraSnapshot {
    let display = try ensureCamera(display: display, operation: operation)
    guard !camera.paused else { throw DesktopWindowError.message("Resume the camera before switching pages.") }
    let (page, overflow) = camera.page.addingReportingOverflow(delta)
    guard !overflow, abs(Double(page)) <= 100_000 else { throw DesktopWindowError.message("The requested camera page is outside the supported range.") }
    return try applyCamera(page: page, display: display, operation: operation)
  }

  private func applyCamera(page: Int, display: DesktopCameraDisplay, operation: DesktopOperation) throws -> DesktopCameraSnapshot {
    if continuousCamera {
      return try applyContinuousCamera(origin: display.origin(page: page).x, display: display, operation: operation, focusArrival: true)
    }
    do {
      let ids = try cameraCandidates(operation: operation)
      if let currentFocusedID, let focused = records[currentFocusedID] {
        pageFocus[focused.snapshot.cameraPage] = currentFocusedID
      }
      // Park departures before restoring arrivals, so foreign originals never receive synthetic input.
      for id in ids where records[id]?.snapshot.cameraPage != page {
        if records[id]?.snapshot.managerMinimized != true {
          try setManagerMinimized(id: id, minimized: true, operation: operation)
        }
      }
      for id in ids where records[id]?.snapshot.cameraPage == page {
        try setManagerMinimized(id: id, minimized: false, operation: operation)
      }
      if let currentFocusedID, let focused = records[currentFocusedID] {
        pageFocus[focused.snapshot.cameraPage] = currentFocusedID
      }
      camera.page = page
      camera.origin = display.origin(page: page)
      let arrivals = ids.filter { records[$0]?.snapshot.cameraPage == page && records[$0]?.snapshot.managerMinimized == false }
      camera.focusTargetID = pageFocus[page].flatMap { arrivals.contains($0) ? $0 : nil } ?? arrivals.first
      camera.detail = nil
      publish()
      return camera
    } catch {
      refreshPendingRecovery()
      camera.paused = true
      camera.detail = "Camera paused: \(error.localizedDescription) Use Restore to release parked windows."
      publish()
      throw error
    }
  }

  func moveFocusedToNewPage(display: DesktopCameraDisplay?, operation: DesktopOperation) throws -> DesktopCameraSnapshot {
    let display = try ensureCamera(display: display, operation: operation)
    guard !camera.paused, let id = currentFocusedID, let record = records[id], record.cameraScopeEligible,
      record.snapshot.cameraPage == camera.page, !record.snapshot.managerMinimized else {
      throw DesktopWindowError.message("Focus a registered visible window before moving it to a new page.")
    }
    try validateWindow(record, operation)
    guard let focused = try read(record.app, kAXFocusedWindowAttribute, operation), CFEqual(focused, record.window),
      onCurrentSpace(record.application.pid, try frame(record.window, operation)) else {
      throw DesktopWindowError.message("The exact focused window is outside the active workspace.")
    }
    guard camera.page < 100_000 else { throw DesktopWindowError.message("The page limit has been reached.") }
    let page = camera.page + 1
    let previous = record.snapshot
    let physical = try frame(record.window, operation)
    pageFocus[page] = id
    records[id]?.snapshot.cameraPage = page
    records[id]?.snapshot.worldFrame = physical.offsetBy(dx: display.origin(page: page).x, dy: 0)
    do { return try applyCamera(page: page, display: display, operation: operation) }
    catch {
      records[id]?.snapshot.cameraPage = previous.cameraPage
      records[id]?.snapshot.worldFrame = previous.worldFrame
      publish()
      throw error
    }
  }

  func setCameraPaused(_ paused: Bool, display: DesktopCameraDisplay?, operation: DesktopOperation) throws -> DesktopCameraSnapshot {
    loadCameraRecovery()
    if paused {
      camera.paused = true
      var failures: [String] = []
      for id in registrationOrder where records[id]?.snapshot.managerMinimized == true || records[id]?.positionManaged == true {
        do { try restoreManagedWindow(id: id, operation: operation) }
        catch { failures.append(error.localizedDescription) }
      }
      do { try reconcileCameraJournal(operation: operation) }
      catch { failures.append(error.localizedDescription) }
      refreshPendingRecovery()
      if failures.isEmpty {
        camera.detail = camera.recoveryCount == 0 ? "Paused. All manager-parked windows are released." : camera.detail
        cameraScopeInvalid = cameraDisplay != nil && cameraDisplay != display
        if cameraScopeInvalid {
          camera.detail = "Windows restored. Return to the original display configuration before resuming."
        }
      } else { camera.detail = failures.joined(separator: " ") }
      publish()
      guard failures.isEmpty else { throw DesktopWindowError.message(camera.detail ?? "Some windows still require recovery.") }
      return camera
    }
    let display = try ensureCamera(display: display, operation: operation)
    camera.paused = false
    if continuousCamera { return try applyContinuousCamera(origin: camera.origin.x, display: display, operation: operation) }
    return try applyCamera(page: camera.page, display: display, operation: operation)
  }

  func reveal(id: UUID, display: DesktopCameraDisplay?, operation: DesktopOperation) throws {
    guard let record = records[id] else { return }
    if record.snapshot.managerMinimized || (!camera.paused && record.snapshot.cameraPage != camera.page) {
      let display = try ensureCamera(display: display, operation: operation)
      _ = try applyCamera(page: record.snapshot.cameraPage, display: display, operation: operation)
    }
  }
}

extension DesktopWindowClient {
  private func runCamera(
    focusArrival: Bool = false, measurement: String? = nil,
    _ work: @escaping @Sendable (DesktopWindowBackend, DesktopCameraDisplay?, DesktopOperation) throws -> DesktopCameraSnapshot,
    completion: @escaping @MainActor @Sendable (Result<DesktopCameraSnapshot, DesktopWindowError>) -> Void
  ) {
    guard !closed, !isCameraBusy else {
      completion(.failure(.message(closed ? "The desktop manager has stopped." : "A camera operation is already running.")))
      return
    }
    cancel()
    isCameraBusy = true
    onChange?()
    let operation = DesktopOperation(timeout: 12)
    cameraOperation = operation
    let backend = backend
    let display = displayProvider()
    let dispatchStart = DispatchTime.now().uptimeNanoseconds
    backend.queue.async { [weak self] in
      let workerStart = DispatchTime.now().uptimeNanoseconds
      let result = Result { try work(backend, display, operation) }
        .mapError { ($0 as? DesktopWindowError) ?? .message($0.localizedDescription) }
      let workerMS = Double(DispatchTime.now().uptimeNanoseconds - workerStart) / 1_000_000
      DispatchQueue.main.async { [weak self] in
        guard let self, self.cameraOperation === operation else { return }
        if let measurement, self.panMetrics != nil {
          if case .success = result {
            let deliveryMS = Double(DispatchTime.now().uptimeNanoseconds - dispatchStart) / 1_000_000
            if measurement == "pan" {
              self.panMetrics?.continuousWorker.append(workerMS)
              self.panMetrics?.continuousDelivery.append(deliveryMS)
            } else {
              self.panMetrics?.discreteWorker.append(workerMS)
              self.panMetrics?.discreteDelivery.append(deliveryMS)
            }
          } else { self.panMetrics?.failedBatches += 1 }
        }
        if focusArrival, case .success(let snapshot) = result, let target = snapshot.focusTargetID {
          self.focus(id: target, cameraOwned: true) { [weak self] focusResult in
            guard let self else { return }
            let final = focusResult.map { _ in snapshot }
            self.finishCamera(operation: operation, result: final, completion: completion)
          }
        } else {
          self.finishCamera(operation: operation, result: result, completion: completion)
        }
      }
    }
  }

  private func finishCamera(
    operation: DesktopOperation, result: Result<DesktopCameraSnapshot, DesktopWindowError>,
    completion: @MainActor @Sendable (Result<DesktopCameraSnapshot, DesktopWindowError>) -> Void
  ) {
    guard cameraOperation === operation else { return }
    cameraOperation = nil
    isCameraBusy = false
    onChange?()
    completion(result)
    if let quit = queuedQuit {
      queuedQuit = nil
      queuedCameraMove = nil
      cancelQueuedPan()
      restoreForQuit(completion: quit)
    } else if let pause = queuedPause {
      queuedPause = nil
      cancelQueuedPan()
      setCameraPaused(true, completion: pause)
    } else if let move = queuedCameraMove {
      queuedCameraMove = nil
      moveCamera(by: move.delta, completion: move.completion)
    } else if let pan = queuedPan {
      queuedPan = nil
      panCamera(by: pan.delta, ended: pan.ended, completion: pan.completion)
    }
  }

  private func cancelQueuedPan() {
    let pan = queuedPan
    queuedPan = nil
    pan?.completion(.failure(.message("Panning was cancelled for a camera command.")))
  }

  func panCamera(
    by delta: CGFloat, ended: Bool = false,
    completion: @escaping @MainActor @Sendable (Result<DesktopCameraSnapshot, DesktopWindowError>) -> Void
  ) {
    guard delta.isFinite else { completion(.failure(.message("Camera input must be finite."))); return }
    guard queuedQuit == nil, queuedPause == nil, queuedCameraMove == nil else {
      completion(.failure(.message("Panning is waiting for the pending camera command.")))
      return
    }
    if isCameraBusy {
      panMetrics?.coalescedPackets += 1
      let previous = queuedPan
      let combined = (previous?.delta ?? 0) + delta
      guard combined.isFinite else { completion(.failure(.message("Camera input overflowed."))); return }
      queuedPan = (combined, ended || previous?.ended == true, completion)
      previous?.completion(.failure(.cameraInputCoalesced))
      return
    }
    runCamera(measurement: delta == 0 ? nil : "pan", { backend, display, operation in
      try backend.panCamera(by: delta, ended: ended, display: display, operation: operation)
    }, completion: completion)
  }

  func moveCamera(by delta: Int, completion: @escaping @MainActor @Sendable (Result<DesktopCameraSnapshot, DesktopWindowError>) -> Void) {
    guard queuedQuit == nil, queuedPause == nil else {
      completion(.failure(.message("Window restoration is already pending.")))
      return
    }
    if isCameraBusy {
      cancelQueuedPan()
      let previous = queuedCameraMove
      let (combined, overflow) = (previous?.delta ?? 0).addingReportingOverflow(delta)
      guard !overflow else { completion(.failure(.message("The requested camera step is too large."))); return }
      queuedCameraMove = (combined, completion)
      previous?.completion(.failure(.message("A newer camera target replaced this queued request.")))
      return
    }
    runCamera(focusArrival: true, measurement: "page", { backend, display, operation in
      try backend.moveCamera(by: delta, display: display, operation: operation)
    }, completion: completion)
  }

  func moveFocusedToNewPage(completion: @escaping @MainActor @Sendable (Result<DesktopCameraSnapshot, DesktopWindowError>) -> Void) {
    runCamera(focusArrival: true, measurement: "page", { backend, display, operation in
      try backend.moveFocusedToNewPage(display: display, operation: operation)
    }, completion: completion)
  }

  func setCameraPaused(_ paused: Bool, completion: @escaping @MainActor @Sendable (Result<DesktopCameraSnapshot, DesktopWindowError>) -> Void) {
    guard queuedQuit == nil else {
      completion(.failure(.message("Quit restoration is already pending.")))
      return
    }
    if paused, isCameraBusy {
      cancelQueuedPan()
      let move = queuedCameraMove
      queuedCameraMove = nil
      move?.completion(.failure(.message("Camera navigation was cancelled for restoration.")))
      let previous = queuedPause
      queuedPause = completion
      previous?(.failure(.message("A newer restoration request replaced this request.")))
      return
    }
    runCamera({ backend, display, operation in
      try backend.setCameraPaused(paused, display: display, operation: operation)
    }, completion: completion)
  }

  func restoreForQuit(completion: @escaping @MainActor @Sendable (Result<DesktopCameraSnapshot, DesktopWindowError>) -> Void) {
    if isCameraBusy {
      cancelQueuedPan()
      let pause = queuedPause
      queuedPause = nil
      pause?(.failure(.message("Pause was replaced by quit restoration.")))
      let previous = queuedQuit
      queuedQuit = completion
      previous?(.failure(.message("A newer quit restoration replaced this request.")))
      if let move = queuedCameraMove {
        queuedCameraMove = nil
        move.completion(.failure(.message("Camera navigation was cancelled for window restoration.")))
      }
      return
    }
    setCameraPaused(true, completion: completion)
  }

  func acknowledgeManualRecovery(completion: @escaping @MainActor @Sendable (Result<DesktopCameraSnapshot, DesktopWindowError>) -> Void) {
    runCamera({ backend, _, _ in try backend.acknowledgeManualRecovery() }, completion: completion)
  }
}

extension DesktopWindowBackend {
  func acknowledgeManualRecovery() throws -> DesktopCameraSnapshot {
    loadCameraRecovery()
    guard let journal = cameraJournal else { throw DesktopWindowError.message("The recovery journal could not be opened.") }
    let owned = Set(records.values.filter { $0.snapshot.managerMinimized || $0.positionManaged }.map { $0.snapshot.id })
    for entry in journal.entries where !owned.contains(entry.id) { try journal.complete(id: entry.id) }
    camera.recoveryCount = 0
    camera.recoveryInstructions = nil
    camera.paused = true
    camera.detail = "Manual recovery acknowledged. Resume the camera when ready."
    publish()
    return camera
  }
}
