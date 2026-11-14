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

  init() {
    focused = a
    available = [a, b]
  }

  func application(pid: pid_t) -> AXUIElement { app }
  func timeout(_ element: AXUIElement) -> Bool { true }
  func pid(_ element: AXUIElement) -> pid_t? { ownerPID }

  func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    readHook?(name)
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

let birth = DesktopProcessIdentity(seconds: 1234, microseconds: 56)
let process = TestProcessIdentity(birth)
let application = DesktopApplicationSnapshot(
  pid: 12001, launchDate: Date(timeIntervalSince1970: 1234), appName: "Fixture",
  bundleIdentifier: "dev.infinitedesk.test", processIdentity: birth)
let ax = FakeDesktopAX()
let backend = DesktopWindowBackend(access: ax, processIdentity: { _ in process.read() })

try backend.queue.sync {
  let aOperation = DesktopOperation()
  let a = try backend.capture(application: application, operation: aOperation)
  backend.commit(id: a.id, operation: aOperation)
  ax.focused = ax.b
  let bOperation = DesktopOperation()
  let b = try backend.capture(application: application, operation: bOperation)
  backend.commit(id: b.id, operation: bOperation)
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
print("Desktop adapter tests passed: exact AX identity, original bounds, cancellation, disappearance, PID reuse, confirmed focus, zero geometry writes.")
