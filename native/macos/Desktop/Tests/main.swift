import AppKit
@preconcurrency import ApplicationServices
import Foundation

final class FakeDesktopAX: DesktopAXAccess {
  let app = AXUIElementCreateApplication(12001)
  let a = AXUIElementCreateApplication(12002)
  let b = AXUIElementCreateApplication(12003)
  var focused: AXUIElement?
  var available: [AXUIElement] = []
  var frames: [CGRect] = [
    CGRect(x: 113, y: 87, width: 620, height: 430),
    CGRect(x: 851, y: 211, width: 510, height: 390),
  ]
  var mutations: [String] = []
  var raises: [AXUIElement] = []
  var acceptFocus = true
  var actionStatus = AXError.success
  var mainWritable = true
  var mainStatus = AXError.success
  var ownerPID: pid_t = 12001
  var readHook: ((String) -> Void)?
  var readFailures: [String: Int] = [:]
  var reads: [String: Int] = [:]

  init() {
    focused = a
    available = [a, b]
  }

  func application(pid: pid_t) -> AXUIElement { app }
  func timeout(_ element: AXUIElement) -> Bool { true }
  func pid(_ element: AXUIElement) -> pid_t? { ownerPID }

  func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    readHook?(name)
    reads[name, default: 0] += 1
    if readFailures[name, default: 0] > 0 {
      readFailures[name, default: 0] -= 1
      return nil
    }
    if CFEqual(element, app) {
      if name == kAXWindowsAttribute { return available as CFArray }
      if name == kAXFocusedWindowAttribute { return focused }
      return nil
    }
    switch name {
    case kAXRoleAttribute: return kAXWindowRole as CFString
    case kAXSubroleAttribute: return kAXStandardWindowSubrole as CFString
    case kAXMinimizedAttribute, "AXFullScreen": return kCFBooleanFalse
    case kAXTitleAttribute: return "Identical title" as CFString
    case kAXPositionAttribute:
      var point = frames[CFEqual(element, a) ? 0 : 1].origin
      return AXValueCreate(.cgPoint, &point)
    case kAXSizeAttribute:
      var size = frames[CFEqual(element, a) ? 0 : 1].size
      return AXValueCreate(.cgSize, &size)
    default: return nil
    }
  }

  func perform(_ element: AXUIElement, _ action: String) -> AXError {
    mutations.append(action)
    if action == kAXRaiseAction {
      raises.append(element)
      if acceptFocus { focused = element }
    }
    return actionStatus
  }
  func mainSettable(_ element: AXUIElement) -> Bool { mainWritable }
  func makeMain(_ element: AXUIElement) -> AXError {
    mutations.append(kAXMainAttribute)
    if mainStatus == .success || mainStatus == .cannotComplete { focused = element }
    return mainStatus
  }
}

// Only this test-controlled process identity crosses the worker boundary; all reads/writes take the lock.
final class TestProcessIdentity: @unchecked Sendable {
  private let lock = NSLock()
  private var value: DesktopProcessIdentity?
  init(_ value: DesktopProcessIdentity) { self.value = value }
  func read() -> DesktopProcessIdentity? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func replace(_ value: DesktopProcessIdentity?) {
    lock.lock()
    self.value = value
    lock.unlock()
  }
}

func require(_ value: @autoclosure () -> Bool, _ message: String) {
  guard value() else { fatalError(message) }
}

func requireFailure(_ message: String, _ body: () throws -> Void) {
  do {
    try body()
    fatalError("Expected failure: \(message)")
  } catch {}
}

final class FakeObserver: DesktopAXObserverHandle {
  struct Subscription {
    let notification: String
    let event: DesktopObservationEvent
  }
  let receive: @Sendable (DesktopObservationEvent) -> Void
  var subscriptions: [Subscription] = []
  var history: [Subscription] = []
  var cancelled = false
  var unsupported: Set<String> = []
  var subscribeHook: ((String) -> Void)?
  var unsubscribeClean = true

  init(receive: @escaping @Sendable (DesktopObservationEvent) -> Void) { self.receive = receive }
  func subscribe(_ element: AXUIElement, notification: String, event: DesktopObservationEvent) -> AXError {
    subscribeHook?(notification)
    guard !unsupported.contains(notification) else { return .notificationUnsupported }
    let subscription = Subscription(notification: notification, event: event)
    subscriptions.append(subscription)
    history.append(subscription)
    return .success
  }
  func unsubscribe(windowID: UUID) -> Bool {
    subscriptions.removeAll { $0.event.windowID == windowID }
    return unsubscribeClean
  }
  func cancel() { cancelled = true; subscriptions.removeAll() }
  func emit(_ notification: String, windowID: UUID? = nil, late: Bool = false) {
    let candidates = late ? history : subscriptions
    guard let subscription = candidates.last(where: {
      $0.notification == notification && $0.event.windowID == windowID
    }) else { fatalError("Missing fake notification subscription") }
    receive(subscription.event)
  }
}

final class FakeObservationProvider: DesktopObservationProvider {
  var handles: [FakeObserver] = []
  var unsupported: Set<String> = []
  var subscribeHook: ((String) -> Void)?
  func create(pid: pid_t, receive: @escaping @Sendable (DesktopObservationEvent) -> Void) throws -> any DesktopAXObserverHandle {
    let handle = FakeObserver(receive: receive)
    handle.unsupported = unsupported
    handle.subscribeHook = subscribeHook
    handles.append(handle)
    return handle
  }
}

// Publication assertions wait for actual worker results, never arbitrary delays.
final class BackendPublications: @unchecked Sendable {
  private let lock = NSLock()
  private let changed = DispatchSemaphore(value: 0)
  private var latest: DesktopBackendState?
  func receive(_ state: DesktopBackendState) {
    lock.lock()
    latest = state
    lock.unlock()
    changed.signal()
  }
  func wait(_ message: String, until predicate: (DesktopBackendState) -> Bool) -> DesktopBackendState {
    let deadline = DispatchTime.now() + 5
    while true {
      lock.lock()
      let state = latest
      lock.unlock()
      if let state, predicate(state) { return state }
      guard changed.wait(timeout: deadline) == .success else { fatalError("Timed out: \(message)") }
    }
  }
}

let birth = DesktopProcessIdentity(seconds: 1234, microseconds: 56)
let process = TestProcessIdentity(birth)
let application = DesktopApplicationSnapshot(
  pid: 12001, launchDate: Date(timeIntervalSince1970: 1234), appName: "Fixture",
  bundleIdentifier: "dev.infinitedesk.test", processIdentity: birth)
let ax = FakeDesktopAX()
let backend = DesktopWindowBackend(
  access: ax, observationProvider: FakeObservationProvider(), permissionCheck: { true },
  processIdentity: { _ in process.read() })

try backend.queue.sync {
  let aOperation = DesktopOperation()
  let a = try backend.capture(application: application, operation: aOperation)
  try backend.commit(id: a.id, operation: aOperation)
  ax.focused = ax.b
  let bOperation = DesktopOperation()
  let b = try backend.capture(application: application, operation: bOperation)
  try backend.commit(id: b.id, operation: bOperation)
  require(a.id != b.id, "Same-title windows must retain distinct identities")
  require(a.originalFrame == ax.frames[0], "Registration must retain A's original bounds")
  require(b.originalFrame == ax.frames[1], "Registration must retain B's original bounds")
  let sameB = try backend.capture(application: application, operation: DesktopOperation())
  require(sameB.id == b.id, "Registering an existing AX element must not duplicate it")
  require(ax.mutations.isEmpty, "Registration must not mutate Accessibility state")
  ax.ownerPID = 12004
  requireFailure("A window owned by another process must not register") {
    _ = try backend.capture(application: application, operation: DesktopOperation())
  }
  ax.ownerPID = application.pid
  var focusReads = 0
  ax.readHook = { name in
    if name == kAXFocusedWindowAttribute {
      focusReads += 1
      if focusReads == 2 { ax.focused = ax.a }
    }
  }
  requireFailure("Duplicate registration must recheck the focused AX identity") {
    _ = try backend.capture(application: application, operation: DesktopOperation())
  }
  ax.readHook = nil

  ax.actionStatus = .cannotComplete
  let uncertainRaise = DesktopOperation()
  try backend.raise(id: a.id, operation: uncertainRaise)
  _ = try backend.confirm(id: a.id, operation: uncertainRaise)
  require(ax.raises.count == 1, "A delivered cannotComplete raise must be confirmed without retry")
  ax.actionStatus = .success

  let original = ax.frames
  for selected in [a, b, a] {
    let operation = DesktopOperation()
    _ = try backend.prepare(id: selected.id, operation: operation)
    try backend.raise(id: selected.id, operation: operation)
    let confirmed = try backend.confirm(id: selected.id, operation: operation)
    require(confirmed.id == selected.id, "Focus confirmation must match the exact selected identity")
  }
  require(ax.frames == original, "A → B → A must preserve real bounds")
  require(ax.mutations.allSatisfy { $0 == kAXRaiseAction }, "Only AXRaise may mutate state")
  require(!ax.mutations.contains(kAXPositionAttribute), "AXPosition write count must be zero")
  require(!ax.mutations.contains(kAXSizeAttribute), "AXSize write count must be zero")

  let delayedB = DesktopOperation()
  _ = try backend.prepare(id: b.id, operation: delayedB)
  delayedB.cancel()
  let aAgain = DesktopOperation()
  try backend.raise(id: a.id, operation: aAgain)
  _ = try backend.confirm(id: a.id, operation: aAgain)
  let raisesBefore = ax.raises.count
  requireFailure("A cancelled delayed B must never raise after A") {
    try backend.raise(id: b.id, operation: delayedB)
  }
  require(ax.raises.count == raisesBefore && CFEqual(ax.focused, ax.a), "Late B must not steal A's input")

  ax.available = [ax.a]
  requireFailure("Closed B must fail before raising any window") {
    try backend.raise(id: b.id, operation: DesktopOperation())
  }
  require(ax.raises.count == raisesBefore && CFEqual(ax.focused, ax.a), "Closed B must leave A unchanged")
  ax.available = [ax.a, ax.b]

  process.replace(DesktopProcessIdentity(seconds: 1235, microseconds: 1))
  requireFailure("Recycled PID must not reuse the registered AX handle") {
    try backend.raise(id: b.id, operation: DesktopOperation())
  }
  require(ax.raises.count == raisesBefore, "PID reuse must cause no action")
  process.replace(nil)
  requireFailure("Exited process must be rejected") {
    _ = try backend.prepare(id: a.id, operation: DesktopOperation())
  }
  process.replace(birth)

  let interrupted = DesktopOperation()
  ax.readHook = { attribute in
    if attribute == kAXWindowsAttribute { interrupted.cancel() }
  }
  requireFailure("Cancellation during AX validation must prevent the following raise") {
    try backend.raise(id: b.id, operation: interrupted)
  }
  ax.readHook = nil
  require(ax.raises.count == raisesBefore, "Cancellation observed after an AX read must prevent mutation")

  requireFailure("Expired operation must not start any AX action") {
    try backend.raise(id: b.id, operation: DesktopOperation(timeout: 0))
  }
  require(ax.raises.count == raisesBefore, "Expired operations must cause no action")

  ax.acceptFocus = false
  try backend.raise(id: b.id, operation: DesktopOperation())
  requireFailure("An application that raises without changing keyboard focus must not report success") {
    _ = try backend.confirm(id: b.id, operation: DesktopOperation())
  }
  let mainOperation = DesktopOperation()
  ax.mainStatus = .cannotComplete
  try backend.makeMain(id: b.id, operation: mainOperation)
  _ = try backend.confirm(id: b.id, operation: mainOperation)
  require(ax.mutations.filter { $0 == kAXMainAttribute }.count == 1, "A delivered Main fallback must be confirmed without retry")
  try backend.makeMain(id: b.id, operation: mainOperation)
  require(ax.mutations.filter { $0 == kAXMainAttribute }.count == 1, "An already focused window requires no Main mutation")
  ax.focused = ax.a
  ax.mainWritable = false
  requireFailure("Unsupported Main must fail without mutation") {
    try backend.makeMain(id: b.id, operation: DesktopOperation())
  }
  ax.mainWritable = true
  let cancelledMain = DesktopOperation()
  cancelledMain.cancel()
  let mainWritesBefore = ax.mutations.filter { $0 == kAXMainAttribute }.count
  requireFailure("A stale Main fallback must never steal focus") {
    try backend.makeMain(id: b.id, operation: cancelledMain)
  }
  require(ax.mutations.filter { $0 == kAXMainAttribute }.count == mainWritesBefore, "Cancelled fallback must cause no Main write")
  ax.mainStatus = .failure
  requireFailure("Main refusal must not report focus") {
    try backend.makeMain(id: b.id, operation: DesktopOperation())
  }
  require(CFEqual(ax.focused, ax.a), "A true Main refusal must leave focus unchanged")
  ax.actionStatus = .failure
  requireFailure("Raise refusal must not report focus") {
    try backend.raise(id: b.id, operation: DesktopOperation())
  }
  require(CFEqual(ax.focused, ax.a), "A true Raise refusal must leave focus unchanged")
  ax.actionStatus = .success
  ax.mainStatus = .success
  ax.acceptFocus = true

  backend.remove(id: b.id)
  requireFailure("Removed registration must not focus") {
    try backend.raise(id: b.id, operation: DesktopOperation())
  }

  ax.focused = ax.b
  let abandoned = try backend.capture(application: application, operation: DesktopOperation())
  backend.discardPending()
  requireFailure("Uncommitted stale registrations must not survive cancellation") {
    _ = try backend.prepare(id: abandoned.id, operation: DesktopOperation())
  }
  ax.frames[1].origin.x += 100
  let current = try backend.capture(application: application, operation: DesktopOperation())
  require(current.originalFrame == ax.frames[1], "A retry must capture fresh original bounds")
  backend.removeAll()
  require(!ax.mutations.contains(kAXPositionAttribute), "All focus paths must have zero AXPosition writes")
  require(!ax.mutations.contains(kAXSizeAttribute), "All focus paths must have zero AXSize writes")
}
require(desktopLaunchDatesCompatible(expected: nil, actual: nil), "Missing Launch Services dates must not invalidate a process fingerprint")
require(desktopLaunchDatesCompatible(expected: application.launchDate, actual: nil), "Unavailable current launchDate must not invalidate the same process")
require(desktopLaunchDatesCompatible(expected: nil, actual: application.launchDate), "An initially unavailable launchDate must remain usable")
require(!desktopLaunchDatesCompatible(expected: Date(timeIntervalSince1970: 1), actual: Date(timeIntervalSince1970: 2)), "Conflicting known dates must be rejected")
let undatedApplication = DesktopApplicationSnapshot(
  pid: application.pid, launchDate: nil, appName: application.appName,
  bundleIdentifier: application.bundleIdentifier, processIdentity: birth)
try backend.queue.sync {
  let operation = DesktopOperation()
  let window = try backend.capture(application: undatedApplication, operation: operation)
  try backend.commit(id: window.id, operation: operation)
  require(window.launchDate == nil && window.processIdentity == birth, "Standalone applications must register using mandatory PID + process start")
  try backend.raise(id: window.id, operation: operation)
  _ = try backend.confirm(id: window.id, operation: operation)
  process.replace(DesktopProcessIdentity(seconds: birth.seconds + 1, microseconds: birth.microseconds))
  requireFailure("An undated application must still reject PID recycling") {
    try backend.raise(id: window.id, operation: DesktopOperation())
  }
  process.replace(birth)
}
require(DesktopProcessIdentity.read(pid: getpid()) != nil, "libproc must identify this actual test subprocess")
print("Desktop adapter tests passed: exact AX identity, original bounds, cancellation, disappearance, PID reuse, confirmed focus, zero geometry writes.")

final class TestPermission: @unchecked Sendable {
  private let lock = NSLock()
  private var value = true
  func read() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
  func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
}

let observedAX = FakeDesktopAX()
let observedProvider = FakeObservationProvider()
let observedProcess = TestProcessIdentity(birth)
let permission = TestPermission()
let updates = BackendPublications()
let observedBackend = DesktopWindowBackend(
  access: observedAX, observationProvider: observedProvider, permissionCheck: { permission.read() },
  processIdentity: { _ in observedProcess.read() })
let observedPair = try observedBackend.queue.sync {
  observedBackend.setUpdateHandler { updates.receive($0) }
  observedBackend.setFrontmost(pid: application.pid)
  let firstOperation = DesktopOperation()
  let first = try observedBackend.capture(application: application, operation: firstOperation)
  try observedBackend.commit(id: first.id, operation: firstOperation)
  observedAX.focused = observedAX.b
  let secondOperation = DesktopOperation()
  let second = try observedBackend.capture(application: application, operation: secondOperation)
  try observedBackend.commit(id: second.id, operation: secondOperation)
  return (first, second)
}
let observedA = observedPair.0
let observedB = observedPair.1
_ = updates.wait("Both windows share one active observer") { state in
  state.windows.count == 2 && state.windows.allSatisfy { $0.observationStatus == .observing }
}
observedBackend.queue.sync {
  require(observedProvider.handles.count == 1, "One process must share exactly one AXObserver")
  require(observedProvider.handles[0].subscriptions.count == 7, "Two windows need one app-focus + six window subscriptions")
}

let finalBurstFrame = CGRect(x: 712, y: 319, width: 843, height: 551)
let burstReadBaseline = observedBackend.queue.sync {
  let baseline = observedAX.reads[kAXPositionAttribute, default: 0]
  let observer = observedProvider.handles[0]
  for index in 0..<10_000 {
    observedAX.frames[0] = CGRect(x: index, y: 319, width: 843, height: 551)
    observer.emit(kAXMovedNotification, windowID: observedA.id)
    observer.emit(kAXResizedNotification, windowID: observedA.id)
  }
  observedAX.frames[0] = finalBurstFrame
  observer.emit(kAXMovedNotification, windowID: observedA.id)
  return baseline
}
let moved = updates.wait("The final event in a move/resize burst must converge") { state in
  state.windows.first(where: { $0.id == observedA.id })?.worldFrame == finalBurstFrame
}
require(moved.windows.first(where: { $0.id == observedA.id })?.originalFrame == observedA.originalFrame,
        "Observed movement must never change originalFrame")
observedBackend.queue.sync {
  require(observedAX.reads[kAXPositionAttribute, default: 0] - burstReadBaseline <= 4,
          "20,001 notifications must coalesce into a bounded number of geometry reads")
  require(observedAX.mutations.isEmpty, "Observation must never mutate any AX state")
  let readsBeforeCallback = observedAX.reads
  observedAX.focused = observedAX.a
  observedProvider.handles[0].emit(kAXFocusedWindowChangedNotification)
  require(observedAX.reads == readsBeforeCallback, "Notification callbacks must enqueue without AX messaging")
}
_ = updates.wait("External focus must identify the exact registered A") { $0.focusedID == observedA.id }
observedBackend.queue.sync {
  observedAX.focused = AXUIElementCreateApplication(12099)
  observedProvider.handles[0].emit(kAXFocusedWindowChangedNotification)
}
_ = updates.wait("An unregistered focused AX element must clear the actual focus ID") { $0.focusedID == nil }

let recoveredFrame = CGRect(x: 83, y: 291, width: 720, height: 505)
observedBackend.queue.sync {
  observedAX.frames[0] = recoveredFrame
  observedAX.readFailures[kAXPositionAttribute] = 1
  observedProvider.handles[0].emit(kAXMovedNotification, windowID: observedA.id)
}
_ = updates.wait("A transient failure on the final geometry notification needs one bounded readback retry") { state in
  state.windows.first(where: { $0.id == observedA.id })?.worldFrame == recoveredFrame
    && state.windows.first(where: { $0.id == observedA.id })?.availability == .available
}
observedBackend.queue.sync {
  observedAX.focused = observedAX.b
  observedAX.readFailures[kAXFocusedWindowAttribute] = 1
  observedProvider.handles[0].emit(kAXFocusedWindowChangedNotification)
}
_ = updates.wait("A transient failure on the final focus notification must converge without another external event") {
  $0.focusedID == observedB.id
}

observedBackend.queue.sync {
  observedAX.available = [observedAX.a]
  observedProvider.handles[0].emit(kAXUIElementDestroyedNotification, windowID: observedB.id)
}
let closed = updates.wait("Destroyed B must remain as a closed DTO, without live AX subscription") { state in
  state.windows.first(where: { $0.id == observedB.id })?.availability == .closed && state.focusedID == nil
}
let closedBFrame = closed.windows.first(where: { $0.id == observedB.id })!.worldFrame
let retiredObserver = observedBackend.queue.sync { observedProvider.handles[0] }
let fenceFrame = recoveredFrame.offsetBy(dx: 1, dy: 1)
observedBackend.queue.sync {
  observedAX.frames[1] = CGRect(x: 999, y: 999, width: 100, height: 100)
  retiredObserver.emit(kAXMovedNotification, windowID: observedB.id, late: true)
  observedAX.frames[0] = fenceFrame
  retiredObserver.emit(kAXMovedNotification, windowID: observedA.id)
}
let afterLateDestroy = updates.wait("A live A event fences the stale B callback") { state in
  state.windows.first(where: { $0.id == observedA.id })?.worldFrame == fenceFrame
}
require(afterLateDestroy.windows.first(where: { $0.id == observedB.id })?.worldFrame == closedBFrame,
        "Late movement must never resurrect or mutate a destroyed registration")
observedBackend.queue.sync {
  observedBackend.remove(id: observedA.id)
  require(retiredObserver.cancelled, "Forgetting the last live window must stop its shared observer")
  require(retiredObserver.subscriptions.isEmpty, "Forget must release observer subscriptions")
  retiredObserver.emit(kAXFocusedWindowChangedNotification, late: true)
  observedAX.focused = observedAX.a
}
let newA = try observedBackend.queue.sync {
  let operation = DesktopOperation()
  let window = try observedBackend.capture(application: application, operation: operation)
  try observedBackend.commit(id: window.id, operation: operation)
  return window
}
_ = updates.wait("A fresh registration after Forget gets a new observer session") { state in
  state.windows.first(where: { $0.id == newA.id })?.observationStatus == .observing
}
require(newA.id != observedA.id && newA.originalFrame == fenceFrame,
        "Recapture must retain fresh geometry and a new registration identity")

permission.set(false)
observedBackend.queue.sync { observedBackend.setFrontmost(pid: application.pid) }
_ = updates.wait("Permission loss must stop observation and mark last geometry unavailable") { state in
  state.windows.first(where: { $0.id == newA.id })?.observationStatus == .paused
    && state.windows.first(where: { $0.id == newA.id })?.availability == .unavailable
    && state.focusedID == nil
}
let beforeResumeObserver = observedBackend.queue.sync { observedProvider.handles.last! }
permission.set(true)
observedBackend.queue.sync { observedBackend.setFrontmost(pid: application.pid) }
_ = updates.wait("Activation must recover permission even if the shell cached true throughout") { state in
  state.windows.first(where: { $0.id == newA.id })?.observationStatus == .observing
    && state.windows.first(where: { $0.id == newA.id })?.availability == .available
}
let resumeFrame = fenceFrame.offsetBy(dx: 7, dy: 3)
observedBackend.queue.sync {
  require(beforeResumeObserver.cancelled, "Permission loss must cancel the previous observer")
  beforeResumeObserver.emit(kAXUIElementDestroyedNotification, windowID: newA.id, late: true)
  observedAX.frames[0] = resumeFrame
  observedProvider.handles.last!.emit(kAXMovedNotification, windowID: newA.id)
}
_ = updates.wait("A retired session cannot destroy a currently subscribed registration") { state in
  state.windows.first(where: { $0.id == newA.id })?.worldFrame == resumeFrame
    && state.windows.first(where: { $0.id == newA.id })?.availability == .available
}

let recycledBirth = DesktopProcessIdentity(seconds: birth.seconds + 10, microseconds: 9)
observedProcess.replace(recycledBirth)
observedBackend.queue.sync {
  observedProvider.handles.last!.emit(kAXMovedNotification, windowID: newA.id)
}
_ = updates.wait("Observer callbacks must not bind a recycled PID to the old registered handle") { state in
  state.windows.first(where: { $0.id == newA.id })?.availability == .closed
}
let recycledApplication = DesktopApplicationSnapshot(
  pid: application.pid, launchDate: nil, appName: application.appName,
  bundleIdentifier: application.bundleIdentifier, processIdentity: recycledBirth)
let recycledA = try observedBackend.queue.sync {
  let operation = DesktopOperation()
  let window = try observedBackend.capture(application: recycledApplication, operation: operation)
  try observedBackend.commit(id: window.id, operation: operation)
  return window
}
_ = updates.wait("A new process incarnation can register normally") { state in
  state.windows.first(where: { $0.id == recycledA.id })?.observationStatus == .observing
}
observedBackend.queue.sync {
  observedBackend.processTerminated(pid: application.pid)
  require(observedBackend.state().windows.first(where: { $0.id == recycledA.id })?.availability == .available,
          "A delayed workspace termination must not close the newer live process")
  observedBackend.removeAll()
  require(observedProvider.handles.allSatisfy(\.cancelled), "Close must stop every observer session")
}

let partialAX = FakeDesktopAX()
let partialProvider = FakeObservationProvider()
partialProvider.unsupported = [kAXMovedNotification]
let partialUpdates = BackendPublications()
let partialBackend = DesktopWindowBackend(
  access: partialAX, observationProvider: partialProvider, permissionCheck: { true },
  processIdentity: { _ in birth })
let partialID = try partialBackend.queue.sync {
  partialBackend.setUpdateHandler { partialUpdates.receive($0) }
  let operation = DesktopOperation()
  let window = try partialBackend.capture(application: application, operation: operation)
  try partialBackend.commit(id: window.id, operation: operation)
  return window.id
}
let partialState = partialUpdates.wait("Unsupported notifications must be reported, not advertised as working") { state in
  state.windows.first(where: { $0.id == partialID })?.observationStatus == .partial
}
require(partialState.windows[0].observationDetail?.contains(kAXMovedNotification) == true,
        "The limitation must identify the unsupported notification")
partialBackend.queue.sync { partialBackend.removeAll() }

let timeoutProvider = FakeObservationProvider()
timeoutProvider.subscribeHook = { notification in
  // Deliberately stalled mock IPC forces the bounded installation rollback path.
  if notification == kAXMovedNotification { Thread.sleep(forTimeInterval: 1.05) }
}
let timeoutUpdates = BackendPublications()
let timeoutBackend = DesktopWindowBackend(
  access: FakeDesktopAX(), observationProvider: timeoutProvider, permissionCheck: { true },
  processIdentity: { _ in birth })
try timeoutBackend.queue.sync {
  timeoutBackend.setUpdateHandler { timeoutUpdates.receive($0) }
  let operation = DesktopOperation()
  let window = try timeoutBackend.capture(application: application, operation: operation)
  try timeoutBackend.commit(id: window.id, operation: operation)
}
_ = timeoutUpdates.wait("Timed-out partial installs must be rolled back") {
  $0.windows.first?.observationStatus == .unsupported
}
timeoutBackend.queue.sync {
  require(timeoutProvider.handles.allSatisfy(\.cancelled), "Partial timeout must cancel an otherwise empty shared observer")
  require(timeoutProvider.handles.allSatisfy { $0.subscriptions.isEmpty }, "Partial timeout must not leave untracked subscriptions")
  timeoutBackend.removeAll()
}
print("Desktop observer tests passed: shared PID observer, burst/final readback, actual focus, immutable original frame, destroy/forget, stale callbacks, permission recovery, PID reuse, partial support, timeout rollback, zero AX writes.")

final class InboxEvents: @unchecked Sendable {
  private let lock = NSLock()
  private let progress = DispatchSemaphore(value: 0)
  private var events: Set<DesktopObservationEvent> = []
  func receive(_ batch: [DesktopObservationEvent]) {
    require(batch.count <= 4, "The callback mailbox must deliver bounded batches")
    lock.lock()
    events.formUnion(batch)
    lock.unlock()
    progress.signal()
  }
  func wait(count: Int) {
    let deadline = DispatchTime.now() + 5
    while true {
      lock.lock()
      let done = events.count == count
      lock.unlock()
      if done { return }
      guard progress.wait(timeout: deadline) == .success else { fatalError("Inbox lost a unique subscribed event") }
    }
  }
}
let largeInboxEvents = InboxEvents()
let largeInboxQueue = DispatchQueue(label: "desktop-tests.large-inbox")
let largeInbox = DesktopObservationInbox(queue: largeInboxQueue) { largeInboxEvents.receive($0) }
largeInboxQueue.sync {
  let session = UUID()
  for _ in 0..<2048 {
    let event = DesktopObservationEvent(session: session, windowID: UUID(), kind: .geometry)
    for _ in 0..<8 { largeInbox.submit(event) }
  }
  largeInbox.submit(.init(session: session, windowID: UUID(), kind: .destroyed))
}
largeInboxEvents.wait(count: 2049)

let survivorProvider = FakeObservationProvider()
var installationCount = 0
survivorProvider.subscribeHook = { notification in
  if notification == kAXMovedNotification {
    installationCount += 1
    if installationCount == 2 { Thread.sleep(forTimeInterval: 1.05) }
  }
}
let survivorUpdates = BackendPublications()
let survivorAX = FakeDesktopAX()
let survivorBackend = DesktopWindowBackend(
  access: survivorAX, observationProvider: survivorProvider, permissionCheck: { true },
  processIdentity: { _ in birth })
let survivorPair = try survivorBackend.queue.sync {
  survivorBackend.setUpdateHandler { survivorUpdates.receive($0) }
  let firstOperation = DesktopOperation()
  let first = try survivorBackend.capture(application: application, operation: firstOperation)
  try survivorBackend.commit(id: first.id, operation: firstOperation)
  survivorAX.focused = survivorAX.b
  let secondOperation = DesktopOperation()
  let second = try survivorBackend.capture(application: application, operation: secondOperation)
  try survivorBackend.commit(id: second.id, operation: secondOperation)
  return (first, second)
}
_ = survivorUpdates.wait("A failed partial install must preserve its already observed sibling") { state in
  state.windows.first(where: { $0.id == survivorPair.0.id })?.observationStatus == .observing
    && state.windows.first(where: { $0.id == survivorPair.1.id })?.observationStatus == .unsupported
}
survivorBackend.queue.sync {
  let handle = survivorProvider.handles[0]
  require(!handle.cancelled, "An existing sibling's shared observer must survive clean window rollback")
  require(handle.subscriptions.count == 4, "Rollback must retain only app focus and the sibling's three notifications")
  require(!handle.subscriptions.contains { $0.event.windowID == survivorPair.1.id }, "No partial subscriptions may survive the failed window install")
  survivorBackend.removeAll()
}
print("Desktop observer scale/lifecycle tests passed: 2049 unique keys, coalesced duplicates, bounded batches, sibling-preserving installation rollback.")
