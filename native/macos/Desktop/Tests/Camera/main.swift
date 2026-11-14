import AppKit
@preconcurrency import ApplicationServices
import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
  guard value() else { fatalError(message) }
}
func failure(_ body: () throws -> Void) {
  do { try body(); fatalError("Expected operation to fail") } catch {}
}
final class CameraAX: DesktopCameraAXAccess {
  let app = AXUIElementCreateApplication(41000)
  let a = AXUIElementCreateApplication(41001)
  let b = AXUIElementCreateApplication(41002)
  let foreign = AXUIElementCreateApplication(41003)
  var focused: AXUIElement?
  var windows: [AXUIElement] = []
  var frames = [CGRect(x: 72, y: 110, width: 620, height: 470), CGRect(x: 400, y: 230, width: 650, height: 490)]
  var minimized = [false, false]
  var roles = [kAXWindowRole, kAXWindowRole]
  var subroles: [String?] = [kAXStandardWindowSubrole, kAXStandardWindowSubrole]
  var useParkedSubrole = false
  var parkedSubrole: String? = kAXDialogSubrole
  var delayedStandardSubroleReads = 0
  var sheets: [AXUIElement] = []
  var reportedPID: pid_t? = 41000
  var writes: [(Int, Bool)] = []
  var positionWrites: [(Int, CGPoint)] = []
  var positionWritable = false
  var clampLeft = false
  var deferNextPosition = false
  var focusWrites = 0
  var focusOnRestore: AXUIElement?
  var afterRestore: (() -> Void)?
  var positionReads = 0
  var attributeRoundTrips = 0
  var batchRequests = 0
  var batchEnabled = true
  var afterBatch: (([String]) -> Void)?
  var refuse = false
  var fullScreen = [false, false]
  var writable = true
  var beforeWrite: (() throws -> Void)?
  var transientFailures: [String: Int] = [:]
  var failuresAfterNextWrite: [String: Int] = [:]
  var staleFrameReadsOnNextRestore = 0
  var staleFrameReads = 0
  var nextWriteStatus = AXError.success
  init() { focused = a; windows = [a, b, foreign] }
  func index(_ element: AXUIElement) -> Int { CFEqual(element, a) ? 0 : 1 }
  func application(pid: pid_t) -> AXUIElement { app }
  func timeout(_ element: AXUIElement) -> Bool { true }
  func pid(_ element: AXUIElement) -> pid_t? { reportedPID }
  func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    attributeRoundTrips += 1
    return attributeValue(element, name)
  }
  func readMultiple(_ element: AXUIElement, _ names: [String], _ operation: DesktopOperation) throws -> [CFTypeRef?] {
    guard batchEnabled else {
      return try names.map { name in
        try operation.check()
        let value = read(element, name)
        try operation.check()
        return value
      }
    }
    try operation.check()
    attributeRoundTrips += 1
    batchRequests += 1
    let values = names.map { attributeValue(element, $0) }
    afterBatch?(names)
    try operation.check()
    return values
  }
  private func attributeValue(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    if transientFailures[name, default: 0] > 0 {
      transientFailures[name, default: 0] -= 1
      return nil
    }
    if CFEqual(element, app) {
      if name == kAXWindowsAttribute { return windows as CFArray }
      if name == kAXFocusedWindowAttribute { return focused }
      return nil
    }
    let index = index(element)
    switch name {
    case kAXRoleAttribute: return roles[index] as CFString
    case kAXSubroleAttribute:
      if minimized[index] && useParkedSubrole { return parkedSubrole.map { $0 as CFString } }
      if delayedStandardSubroleReads > 0 {
        delayedStandardSubroleReads -= 1
        return kAXDialogSubrole as CFString
      }
      return subroles[index].map { $0 as CFString }
    case "AXSheets": return sheets as CFArray
    case kAXTitleAttribute: return "Same title" as CFString
    case kAXMinimizedAttribute: return minimized[index] ? kCFBooleanTrue : kCFBooleanFalse
    case "AXFullScreen": return fullScreen[index] ? kCFBooleanTrue : kCFBooleanFalse
    case kAXPositionAttribute:
      positionReads += 1
      var point = frames[index].origin
      if staleFrameReads > 0, !minimized[index] { staleFrameReads -= 1; point.x += 80 }
      return AXValueCreate(.cgPoint, &point)
    case kAXSizeAttribute:
      var size = frames[index].size
      return AXValueCreate(.cgSize, &size)
    default: return nil
    }
  }
  func perform(_ element: AXUIElement, _ action: String) -> AXError { focusWrites += 1; focused = element; return .success }
  func mainSettable(_ element: AXUIElement) -> Bool { true }
  func makeMain(_ element: AXUIElement) -> AXError { focused = element; return .success }
  func settable(_ element: AXUIElement, _ name: String) -> Bool { writable && (name == kAXMinimizedAttribute || (name == kAXPositionAttribute && positionWritable)) }
  func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> AXError {
    expect(!CFEqual(element, foreign), "Unregistered windows must never be mutated")
    expect(name == kAXMinimizedAttribute || positionWritable, "Page transitions must never write offscreen geometry")
    do { try beforeWrite?() } catch { fatalError("Missing durable recovery intent") }
    if name == kAXPositionAttribute {
      var point = CGPoint.zero
      expect(AXValueGetValue(value as! AXValue, .cgPoint, &point), "Position write encodes CGPoint")
      positionWrites.append((index(element), point))
      if refuse { return .failure }
      if clampLeft { point.x = max(0, point.x) }
      if deferNextPosition { deferNextPosition = false } else { frames[index(element)].origin = point }
      let status = nextWriteStatus
      nextWriteStatus = .success
      return status
    }
    let state = value as! Bool
    writes.append((index(element), state))
    if refuse { return .failure }
    minimized[index(element)] = state
    transientFailures = failuresAfterNextWrite
    failuresAfterNextWrite = [:]
    if !state {
      if let focusOnRestore { focused = focusOnRestore }
      afterRestore?()
      staleFrameReads = staleFrameReadsOnNextRestore
      staleFrameReadsOnNextRestore = 0
    }
    let status = nextWriteStatus
    nextWriteStatus = .success
    return status
  }
}
final class NoObserver: DesktopObservationProvider {
  func create(pid: pid_t, receive: @escaping @Sendable (DesktopObservationEvent) -> Void) throws -> any DesktopAXObserverHandle {
    throw DesktopWindowError.message("Not used by synchronous camera tests")
  }
}
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InfiniteDesk-camera-tests-\(UUID())")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let journalURL = folder.appendingPathComponent("recovery.json")
let journal = try DesktopCameraJournal(fileURL: journalURL)
let ax = CameraAX()
let birth = DesktopProcessIdentity(seconds: 1, microseconds: 2)
let app = DesktopApplicationSnapshot(pid: 41000, launchDate: nil, appName: "Test", bundleIdentifier: nil, processIdentity: birth)
let display = DesktopCameraDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1000))
let backend = DesktopWindowBackend(access: ax, observationProvider: NoObserver(), permissionCheck: { true }, cameraJournal: journal, onCurrentSpace: { _, _ in true }, processIdentity: { _ in birth })
ax.beforeWrite = {
  let data = try Data(contentsOf: journalURL)
  let saved = try JSONSerialization.jsonObject(with: data) as! [String: Any]
  expect(!(saved["entries"] as! [Any]).isEmpty, "Recovery intent must exist on disk before AX write")
}
try backend.queue.sync {
  backend.setFrontmost(pid: app.pid)
  let operation = DesktopOperation(timeout: 10)
  let a = try backend.capture(application: app, operation: operation)
  try backend.commit(id: a.id, operation: operation)
  ax.focused = ax.b
  let b = try backend.capture(application: app, operation: operation)
  try backend.commit(id: b.id, operation: operation)
  let originals = ax.frames
  ax.failuresAfterNextWrite = [kAXRoleAttribute: 2, kAXWindowsAttribute: 2, "AXFullScreen": 2]
  ax.nextWriteStatus = .cannotComplete
  let moved = try backend.moveFocusedToNewPage(display: display, operation: operation)
  expect(moved.page == 1 && moved.origin.x == 1920, "Move and follow must select a separate page")
  expect(moved.focusTargetID == b.id, "Move and follow must preserve exact native arrival target")
  expect(ax.minimized == [true, false], "Only departing registered A must park")
  expect(ax.writes.count == 1 && ax.transientFailures.values.allSatisfy { $0 == 0 }, "Temporary animation AX failures and cannotComplete must converge without duplicate writes")
  expect(journal.entries.count == 1, "Only parked A requires recovery")
  let worldB = backend.state().windows.first { $0.id == b.id }!.worldFrame
  expect(worldB.minX == originals[1].minX + 1920, "B world position must exceed a display width")
  expect(ax.frames == originals, "Registration and first camera transition preserve actual geometry")
  ax.staleFrameReadsOnNextRestore = 4
  let returned = try backend.moveCamera(by: -1, display: display, operation: operation)
  expect(ax.staleFrameReads == 0, "Restoration must wait for bounds to converge after the animation")
  expect(returned.focusTargetID == a.id, "Returning to A must request its exact handle for native focus")
  expect(ax.minimized == [false, true], "A -> B -> A must restore the exact A")
  expect(backend.state().windows.first { $0.id == b.id }!.worldFrame == worldB, "World B survives a round trip")
  _ = try backend.moveCamera(by: 1, display: display, operation: operation)
  ax.frames[1].origin.x += 117
  _ = try backend.confirm(id: b.id, operation: operation)
  expect(backend.state().windows.first { $0.id == b.id }!.worldFrame.minX == ax.frames[1].minX + 1920, "Manual drag on page 1 must include camera origin")
  _ = try backend.setCameraPaused(true, display: display, operation: operation)
  expect(ax.minimized == [false, false] && journal.entries.isEmpty, "Pause releases all manager-owned minimization and durable intents")
  let stable = backend.state().windows.map(\.worldFrame)
  _ = try backend.setCameraPaused(false, display: display, operation: operation)
  expect(ax.minimized == [true, false], "Resume reapplies current page")
  expect(backend.state().windows.map(\.worldFrame) == stable, "Pause and resume preserve world frames")
  expect(backend.remove(id: a.id), "Forget must release parked A")
  expect(!ax.minimized[0] && journal.entries.isEmpty, "Forget restores the original before releasing ownership")
  _ = try backend.setCameraPaused(true, display: display, operation: operation)
  ax.minimized[1] = true
  let writes = ax.writes.count
  _ = try backend.setCameraPaused(false, display: display, operation: operation)
  _ = try backend.moveCamera(by: 1, display: display, operation: operation)
  expect(ax.writes.count == writes && ax.minimized[1], "An owner-minimized window is excluded and never restored")
  ax.minimized[1] = false
  ax.refuse = true
  failure { _ = try backend.moveCamera(by: 1, display: display, operation: operation) }
  expect(backend.state().camera.paused && !journal.entries.isEmpty, "A refused write pauses with recovery intent retained")
  ax.refuse = false
  _ = try backend.setCameraPaused(true, display: display, operation: operation)
  expect(journal.entries.isEmpty, "Explicit restore resolves an uncertain failed write")
  failure { _ = try backend.moveCamera(by: Int.max, display: display, operation: operation) }
  ax.writable = false
  let beforeUnsupported = ax.writes.count
  failure { _ = try backend.setCameraPaused(false, display: display, operation: operation) }
  expect(backend.state().camera.paused && ax.writes.count == beforeUnsupported, "Unsupported parking must pause before any mutation")
  ax.writable = true
  _ = try backend.setCameraPaused(false, display: display, operation: operation)
  expect(ax.minimized[1], "B must park when its page is outside the camera")
  ax.minimized[1] = false
  _ = try backend.moveCamera(by: 0, display: display, operation: operation)
  let adoptedB = backend.state().windows.first { $0.id == b.id }!
  expect(adoptedB.cameraPage == 2 && !ax.minimized[1], "Explicit owner deminiaturization adopts B into the current page")
  expect(journal.entries.isEmpty, "Owner deminiaturization releases its recovery entry")
  backend.invalidateCameraScope()
  let scopeWrites = ax.writes.count
  failure { _ = try backend.moveCamera(by: 1, display: display, operation: operation) }
  expect(ax.writes.count == scopeWrites, "A Space change blocks all camera writes until explicit restore")
  _ = try backend.setCameraPaused(true, display: display, operation: operation)
}
print("Desktop camera tests passed: durable intent before mutation, world projection, discrete pages, exact parked originals, drag, pause/resume, forget, owner minimization, refused IPC, bounded page range.")

let panJournalURL = folder.appendingPathComponent("pan-recovery.json")
let panJournal = try DesktopCameraJournal(fileURL: panJournalURL)
let panAX = CameraAX()
panAX.positionWritable = true
let panBackend = DesktopWindowBackend(access: panAX, observationProvider: NoObserver(), permissionCheck: { true }, cameraJournal: panJournal, onCurrentSpace: { _, _ in true }, processIdentity: { _ in birth })
panAX.beforeWrite = {
  let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: panJournalURL)) as! [String: Any]
  expect(!(saved["entries"] as! [Any]).isEmpty, "Pan original must be durable before every native mutation")
}
try panBackend.queue.sync {
  let operation = DesktopOperation(timeout: 60)
  panBackend.setFrontmost(pid: app.pid)
  let a = try panBackend.capture(application: app, operation: operation)
  try panBackend.commit(id: a.id, operation: operation)
  panAX.focused = panAX.b
  let b = try panBackend.capture(application: app, operation: operation)
  try panBackend.commit(id: b.id, operation: operation)
  let originals = panAX.frames
  let moved = try panBackend.panCamera(by: 100.5, display: display, operation: operation)
  expect(moved.origin.x == 100.5 && moved.page == 0 && moved.focusTargetID == nil, "Pan origin must retain fractional points without requesting focus")
  expect(panAX.frames[0].minX == -28.5, "Partially visible native originals must use public AXPosition")
  expect(panBackend.state().windows.map(\.worldFrame) == originals, "Pan projection cannot alter virtual geometry")
  expect(panAX.positionWrites.count == 2 && panAX.writes.isEmpty && panAX.focusWrites == 0, "Visible pan moves positions without minimizing or focusing")
  let durable = panJournal.durableCommitCount
  let readsBeforeTicks = panAX.positionReads
  let roundTripsBeforeTicks = panAX.attributeRoundTrips
  let batchesBeforeTicks = panAX.batchRequests
  for _ in 0..<200 { _ = try panBackend.panCamera(by: 0.125, display: display, operation: operation) }
  expect(panJournal.durableCommitCount == durable, "Continuous movement cannot fsync per input tick")
  expect(panAX.positionReads - readsBeforeTicks == 800, "Each visible window uses one candidate frame sample plus fresh post-write readback per batch")
  expect(panAX.attributeRoundTrips - roundTripsBeforeTicks == 2400 && panAX.batchRequests - batchesBeforeTicks == 1600,
    "Each visible window keeps both exact identity checks and two frame samples using six attribute round trips")
  let reversed = try panBackend.panCamera(by: -70.25, ended: true, display: display, operation: operation)
  expect(reversed.origin.x == 55.25, "Quick reversal must retain exact accumulated fractional origin")
  let writeCount = panAX.positionWrites.count
  _ = try panBackend.panCamera(by: 0, ended: true, display: display, operation: operation)
  expect(panAX.positionWrites.count == writeCount, "A zero end packet audits without a position mutation")
  panAX.frames[0].origin.x += 37
  panAX.focused = panAX.a
  _ = try panBackend.confirm(id: a.id, operation: operation)
  let dragged = panBackend.state().windows.first { $0.id == a.id }!.worldFrame
  expect(dragged.minX == originals[0].minX + 37, "Manual drag changes world geometry using fractional current origin")
  let restorationA = panAX.frames[0]
  expect(panJournal.entries.first { $0.id == a.id }!.restorationFrame == restorationA, "Accepted user drag must durably replace restoration target")
  _ = try panBackend.panCamera(by: 2500, display: display, operation: operation)
  expect(panAX.minimized == [true, true], "Fully offscreen windows must be parked without a visible strip")
  _ = try panBackend.panCamera(by: -2500, display: display, operation: operation)
  expect(panAX.minimized == [false, false], "Returning restores only manager-owned parked windows")
  let world = panBackend.state().windows.map(\.worldFrame)
  _ = try panBackend.setCameraPaused(true, display: display, operation: operation)
  expect(panAX.frames[0] == restorationA && panAX.frames[1] == originals[1] && panJournal.entries.isEmpty, "Pause restores durable originals and accepted manual drag target")
  _ = try panBackend.setCameraPaused(false, display: display, operation: operation)
  expect(panBackend.state().windows.map(\.worldFrame) == world, "Resume cannot rebase preserved virtual positions from restored native frames")
  _ = try panBackend.moveCamera(by: 1, display: display, operation: operation)
  expect(panBackend.state().camera.origin.x == 1920 && panAX.minimized == [true, true], "Discrete page navigation projects the same continuous world")
  _ = try panBackend.moveCamera(by: -1, display: display, operation: operation)
  expect(panBackend.state().windows.map(\.worldFrame) == world && !panAX.minimized.contains(true), "Continuous-to-page round trip preserves exact world geometry")
  panAX.clampLeft = true
  let clipped = try panBackend.panCamera(by: 200, display: display, operation: operation)
  expect(clipped.detail != nil && panAX.frames[0].minX == 0, "Native partial visibility constraints must be reported")
  expect(panBackend.state().windows.map(\.worldFrame) == world, "Native constraints cannot rewrite world geometry")
  panAX.clampLeft = false
  _ = try panBackend.setCameraPaused(true, display: display, operation: operation)
  expect(panJournal.entries.isEmpty && panAX.focusWrites == 0, "Pan never changes focus; confirmation reads focus without native focus writes")
  _ = try panBackend.setCameraPaused(false, display: display, operation: operation)
  let beforeUncertain = panJournal.durableCommitCount
  panAX.deferNextPosition = true
  panAX.nextWriteStatus = .cannotComplete
  failure { _ = try panBackend.panCamera(by: 5, display: display, operation: operation) }
  expect(panBackend.state().camera.paused && panBackend.state().camera.requiresRestoration && !panJournal.entries.isEmpty, "Position-only ownership must expose restoration after an uncertain paused pan")
  panAX.frames[0].origin = panAX.positionWrites.last!.1
  _ = try panBackend.confirm(id: a.id, operation: operation)
  expect(panJournal.durableCommitCount == beforeUncertain, "Late manager geometry after uncertain IPC cannot become user drag or write disk")
  _ = try panBackend.setCameraPaused(true, display: display, operation: operation)
  expect(panJournal.entries.isEmpty && !panBackend.state().camera.requiresRestoration, "Explicit Pause resolves uncertain delivered native position and clears restoration control state")
  _ = try panBackend.setCameraPaused(false, display: display, operation: operation)
  panAX.minimized[1] = true
  failure { _ = try panBackend.setCameraPaused(true, display: display, operation: operation) }
  expect(panAX.minimized[1] && panJournal.entries.contains { $0.id == b.id }, "User-minimized position-owned window cannot be unminimized by Pause")
  panAX.minimized[1] = false
  _ = try panBackend.setCameraPaused(true, display: display, operation: operation)
  expect(panJournal.entries.isEmpty, "Owner unminimization allows explicit recovery to finish")
}
print("Continuous camera tests passed: fractional AX projection, bounded disk writes, reversal, end audit, native clipping, drag recovery, parking, Pause/Resume, page interoperability.")

let overviewAX = CameraAX()
overviewAX.positionWritable = true
let overviewBackend = DesktopWindowBackend(access: overviewAX, observationProvider: NoObserver(), permissionCheck: { true },
  cameraJournal: try DesktopCameraJournal(fileURL: folder.appendingPathComponent("overview.json")),
  onCurrentSpace: { _, _ in true }, processIdentity: { _ in birth })
try overviewBackend.queue.sync {
  let operation = DesktopOperation(timeout: 10)
  overviewBackend.setFrontmost(pid: app.pid)
  let a = try overviewBackend.capture(application: app, operation: operation)
  try overviewBackend.commit(id: a.id, operation: operation)
  overviewAX.focused = overviewAX.b
  let b = try overviewBackend.capture(application: app, operation: operation)
  try overviewBackend.commit(id: b.id, operation: operation)
  _ = try overviewBackend.moveFocusedToNewPage(display: display, operation: operation)
  let before = overviewBackend.state().windows.map(\.worldFrame)
  let writes = overviewAX.positionWrites.count
  try overviewBackend.reveal(id: b.id, display: display, operation: operation, fromOverview: true)
  expect(overviewAX.positionWrites.count == writes && overviewBackend.state().camera.origin.x == 1920,
    "Overview selection of an already visible original must not move the camera")
  try overviewBackend.reveal(id: a.id, display: display, operation: operation, fromOverview: true)
  expect(overviewBackend.state().camera.origin.x == a.originalFrame.minX && !overviewAX.minimized[0],
    "Returning to the parked window from the right only reveals its left edge to the start of the display")
  try overviewBackend.reveal(id: b.id, display: display, operation: operation, fromOverview: true)
  expect(overviewBackend.state().camera.origin.x == before[1].maxX - display.visibleFrame.maxX && !overviewAX.minimized[1],
    "Returning from the left reveals the exact chosen window at the opposite edge")
  expect(overviewBackend.state().windows.map(\.worldFrame) == before, "Overview navigation must preserve world coordinates")
  _ = try overviewBackend.setCameraPaused(true, display: display, operation: operation)
  expect(overviewAX.frames == [a.originalFrame,b.originalFrame], "Pause must restore both originals after overview navigation")
}
print("Overview navigation tests passed: visible selection, minimal reveal from either side, stable world frames and restoration.")

@MainActor
func verifyClientCoalescing() async throws {
  let store = try DesktopCameraJournal(fileURL: folder.appendingPathComponent("client-recovery.json"))
  let adapter = CameraAX()
  adapter.positionWritable = true
  let worker = DesktopWindowBackend(access: adapter, observationProvider: NoObserver(), permissionCheck: { true }, cameraJournal: store, onCurrentSpace: { _, _ in true }, processIdentity: { _ in birth })
  let client = DesktopWindowClient(backend: worker, displayProvider: { display })
  try worker.queue.sync {
    worker.setPermission(true)
    worker.setFrontmost(pid: app.pid)
    let operation = DesktopOperation(timeout: 10)
    let window = try worker.capture(application: app, operation: operation)
    try worker.commit(id: window.id, operation: operation)
  }
  var coalesced = 0
  var applied = 0
  await withCheckedContinuation { continuation in
    client.panCamera(by: 10) { result in
      if case .success = result { applied += 1 } else { fatalError("Initial client pan must apply") }
    }
    client.panCamera(by: 20) { result in
      if case .failure(.cameraInputCoalesced) = result { coalesced += 1 } else { fatalError("Queued packet must report coalescing explicitly") }
    }
    client.panCamera(by: -20) { result in
      if case .failure(.cameraInputCoalesced) = result { coalesced += 1 } else { fatalError("Reversal packet must report coalescing explicitly") }
    }
    client.panCamera(by: 0, ended: true) { result in
      expect((try? result.get().origin.x) == 10, "Net zero reversal and final flush must preserve actual first batch origin")
      continuation.resume()
    }
  }
  expect(applied == 1 && coalesced == 2, "Only applied batches can acknowledge geometry; pending callback storage stays one")
  expect(worker.queue.sync { adapter.positionWrites.count } == 1, "Coalesced net zero end must never write redundant native geometry")
  await withCheckedContinuation { continuation in
    client.panCamera(by: 5) { result in expect((try? result.get()) != nil, "In-flight batch finishes before Pause") }
    client.panCamera(by: 7) { result in
      expect((try? result.get()) == nil, "Queued pan is cancelled for Pause")
    }
    client.setCameraPaused(true) { result in
      expect((try? result.get().paused) == true, "Pause must wait for the worker and restore")
      continuation.resume()
    }
  }
  expect(worker.queue.sync { store.entries.isEmpty && adapter.frames[0] == CGRect(x: 72, y: 110, width: 620, height: 470) }, "Queued Pause releases all original ownership")
  client.close()
}
try await verifyClientCoalescing()
print("Client camera tests passed: bounded packet coalescing, exact zero reversal flush, callback confirmation, queued Pause restoration.")

final class FocusInputGeneration: @unchecked Sendable {
  private let lock = NSLock()
  private var value: UInt64 = 0
  func read() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
  func advance() { lock.lock(); value += 1; lock.unlock() }
}
func verifyUnparkFocus(takeover: Bool, foreign: Bool, active: Bool, pause: Bool = false, changedFrontmost: Bool = false) throws {
  let store = try DesktopCameraJournal(fileURL: folder.appendingPathComponent("focus-recovery-\(UUID()).json"))
  let adapter = CameraAX()
  adapter.positionWritable = true
  let generation = FocusInputGeneration()
  let worker = DesktopWindowBackend(access: adapter, observationProvider: NoObserver(), permissionCheck: { true }, cameraJournal: store, onCurrentSpace: { _, _ in true }, applicationIsActive: { _ in active }, userInputGeneration: { generation.read() }, processIdentity: { _ in birth })
  try worker.queue.sync {
    let operation = DesktopOperation(timeout: 20)
    worker.setFrontmost(pid: app.pid)
    let a = try worker.capture(application: app, operation: operation)
    try worker.commit(id: a.id, operation: operation)
    adapter.focused = adapter.b
    let b = try worker.capture(application: app, operation: operation)
    try worker.commit(id: b.id, operation: operation)
    _ = try worker.moveFocusedToNewPage(display: display, operation: operation)
    expect(adapter.minimized == [true, false], "Focus fixture must park only A while B remains focused")
    adapter.focusOnRestore = foreign ? adapter.foreign : adapter.a
    adapter.afterRestore = {
      if takeover { generation.advance() }
      if changedFrontmost { worker.setFrontmost(pid: app.pid + 1) }
    }
    if pause {
      _ = try worker.setCameraPaused(true, display: display, operation: operation)
      expect(adapter.minimized == [false, false] && store.entries.isEmpty,
        "Pause must release parked A while retaining physically visible B")
    } else {
      _ = try worker.panCamera(by: -1420, ended: true, display: display, operation: operation)
    }
    let repairExpected = active && !takeover && !foreign && !changedFrontmost
    expect(adapter.focusWrites == (repairExpected ? 1 : 0), "Only proven system displacement can trigger one sibling focus repair")
    if repairExpected {
      expect(CFEqual(adapter.focused!, adapter.b) && worker.state().focusedID == b.id, "Native auto-focus on arriving A must return to the exact previously focused B")
      if !pause {
        adapter.focusOnRestore = nil
        _ = try worker.panCamera(by: 1, display: display, operation: operation)
        expect(adapter.focusWrites == 1, "Normal continuous position ticks must never perform focus actions")
      }
    } else {
      expect(CFEqual(adapter.focused!, foreign ? adapter.foreign : adapter.a), "User takeover and third-party focus changes must be preserved")
    }
    adapter.focusOnRestore = nil
    _ = try worker.setCameraPaused(true, display: display, operation: operation)
  }
}
try verifyUnparkFocus(takeover: false, foreign: false, active: true)
try verifyUnparkFocus(takeover: true, foreign: false, active: true)
try verifyUnparkFocus(takeover: false, foreign: true, active: true)
try verifyUnparkFocus(takeover: false, foreign: false, active: false)
print("Continuous unpark focus tests passed: exact sibling preservation, zero per-tick focus, no third-party/takeover/background focus stealing.")
try verifyUnparkFocus(takeover: false, foreign: false, active: true, pause: true)
try verifyUnparkFocus(takeover: true, foreign: false, active: true, pause: true)
try verifyUnparkFocus(takeover: false, foreign: true, active: true, pause: true)
try verifyUnparkFocus(takeover: false, foreign: false, active: false, pause: true)
try verifyUnparkFocus(takeover: false, foreign: false, active: true, pause: true, changedFrontmost: true)
print("Pause unpark focus tests passed: visible exact sibling retained; no repair after user takeover, foreign focus, inactive app or frontmost PID change.")

#if DESKTOP_AX_BATCH_EXPERIMENT
var attributeError = AXError.attributeUnsupported
let errorValue = AXValueCreate(.axError, &attributeError)!
let decoded = SystemDesktopAXAccess.multipleValues(
  [kAXWindowRole as CFString, kCFNull!, errorValue, kCFBooleanFalse!] as CFArray, count: 4)
expect(decoded[0] as? String == kAXWindowRole && decoded[1] == nil && decoded[2] == nil && decoded[3] as? Bool == false,
  "Native batch errors and CFNull must preserve attribute positions without becoming successful values")
expect(SystemDesktopAXAccess.multipleValues(nil, count: 2).allSatisfy { $0 == nil }
  && SystemDesktopAXAccess.multipleValues([kCFBooleanFalse!] as CFArray, count: 2).allSatisfy { $0 == nil },
  "Missing or truncated native batches must fail every requested attribute")
#endif

final class CameraSafetyState: @unchecked Sendable {
  private let lock = NSLock()
  private var permission = true
  private var identity = birth
  func permitted() -> Bool { lock.lock(); defer { lock.unlock() }; return permission }
  func process() -> DesktopProcessIdentity { lock.lock(); defer { lock.unlock() }; return identity }
  func revoke() { lock.lock(); permission = false; lock.unlock() }
  func restorePermission() { lock.lock(); permission = true; lock.unlock() }
  func replaceProcess() { lock.lock(); identity = .init(seconds: 3, microseconds: 4); lock.unlock() }
}

func verifyBatchedSafety(_ scenario: String) throws {
  let adapter = CameraAX()
  adapter.positionWritable = true
  let safety = CameraSafetyState()
  let store = try DesktopCameraJournal(fileURL: folder.appendingPathComponent("batch-safety-\(UUID()).json"))
  let worker = DesktopWindowBackend(access: adapter, observationProvider: NoObserver(),
    permissionCheck: { safety.permitted() }, cameraJournal: store,
    onCurrentSpace: { _, _ in true }, processIdentity: { _ in safety.process() })
  try worker.queue.sync {
    let operation = DesktopOperation(timeout: 20)
    worker.setFrontmost(pid: app.pid)
    let selected = try worker.capture(application: app, operation: operation)
    try worker.commit(id: selected.id, operation: operation)
    _ = try worker.panCamera(by: 5, display: display, operation: operation)
    let before = adapter.positionWrites.count
    switch scenario {
    case "permission": safety.revoke()
    case "Space": worker.invalidateCameraScope()
    case "membership": adapter.windows = [adapter.b, adapter.foreign]
    case "prewrite-membership", "prewrite-process", "prewrite-partial":
      adapter.afterBatch = { names in
        guard names == [kAXPositionAttribute, kAXSizeAttribute] else { return }
        adapter.afterBatch = nil
        switch scenario {
        case "prewrite-membership": adapter.windows = [adapter.b, adapter.foreign]
        case "prewrite-process": safety.replaceProcess()
        default: adapter.transientFailures[kAXRoleAttribute] = 1
        }
      }
    default: adapter.transientFailures[scenario] = 1
    }
    if ["permission", "Space", "prewrite-membership", "prewrite-process", "prewrite-partial"].contains(scenario) {
      failure { _ = try worker.panCamera(by: 5, display: display, operation: operation) }
    } else {
      _ = try worker.panCamera(by: 5, display: display, operation: operation)
      expect(worker.state().windows.first!.availability == .unavailable, "Partial sample or changed membership must mark the exact window unavailable")
    }
    expect(adapter.positionWrites.count == before && adapter.writes.isEmpty,
      "\(scenario) must block every native mutation without falling back to a same-title sibling")
    expect(!store.entries.isEmpty, "\(scenario) cannot discard existing position restoration ownership")
    adapter.windows = [adapter.a, adapter.b, adapter.foreign]
    safety.restorePermission()
    if scenario == "prewrite-process" {
      failure { _ = try worker.setCameraPaused(true, display: display, operation: operation) }
      expect(!store.entries.isEmpty && adapter.positionWrites.count == before,
        "Process replacement must retain manual recovery and refuse restoration to a reused PID")
    } else {
      _ = try worker.setCameraPaused(true, display: display, operation: operation)
      expect(store.entries.isEmpty && adapter.frames[0] == CGRect(x: 72, y: 110, width: 620, height: 470),
        "\(scenario) must still restore the exact registered original after its safety gate recovers")
    }
  }
}
for scenario in ["permission", "Space", "membership", "prewrite-membership", "prewrite-process", "prewrite-partial",
  kAXRoleAttribute, kAXSubroleAttribute, "AXFullScreen", kAXMinimizedAttribute, kAXPositionAttribute, kAXSizeAttribute] {
  try verifyBatchedSafety(scenario)
}

func attributeTripsForPan(batchEnabled: Bool) throws -> Int {
  let adapter = CameraAX()
  adapter.batchEnabled = batchEnabled
  adapter.positionWritable = true
  let store = try DesktopCameraJournal(fileURL: folder.appendingPathComponent("batch-count-\(UUID()).json"))
  let worker = DesktopWindowBackend(access: adapter, observationProvider: NoObserver(), permissionCheck: { true },
    cameraJournal: store, onCurrentSpace: { _, _ in true }, processIdentity: { _ in birth })
  return try worker.queue.sync {
    let operation = DesktopOperation(timeout: 20)
    worker.setFrontmost(pid: app.pid)
    let selected = try worker.capture(application: app, operation: operation)
    try worker.commit(id: selected.id, operation: operation)
    _ = try worker.panCamera(by: 5, display: display, operation: operation)
    let before = adapter.attributeRoundTrips
    let commits = store.durableCommitCount
    for _ in 0..<100 { _ = try worker.panCamera(by: 0.125, display: display, operation: operation) }
    let count = adapter.attributeRoundTrips - before
    expect(store.durableCommitCount == commits && adapter.focusWrites == 0,
      "Attribute batching must preserve bounded durability and zero continuous focus changes")
    _ = try worker.setCameraPaused(true, display: display, operation: operation)
    expect(store.entries.isEmpty && adapter.frames[0] == CGRect(x: 72, y: 110, width: 620, height: 470),
      "Sequential and batched reads must both restore the same exact original")
    return count
  }
}
let sequentialTrips = try attributeTripsForPan(batchEnabled: false)
let batchedTrips = try attributeTripsForPan(batchEnabled: true)
expect(sequentialTrips == 1600 && batchedTrips == 600, "One hundred same-workload visible pans must reduce attribute round trips from 1600 to 600; observed \(sequentialTrips) and \(batchedTrips)")
print("Batched AX tests passed: \(sequentialTrips) -> \(batchedTrips) attribute round trips for 100 visible pans; partial errors, fresh exact membership/process checks, permission, Space, and durable restoration preserved.")

func verifyOwnedParkedDialog(_ scenario: String) throws {
  let adapter = CameraAX()
  adapter.useParkedSubrole = true
  let safety = CameraSafetyState()
  let store = try DesktopCameraJournal(fileURL: folder.appendingPathComponent("parked-dialog-\(UUID()).json"))
  let worker = DesktopWindowBackend(access: adapter, observationProvider: NoObserver(), permissionCheck: { true },
    cameraJournal: store, onCurrentSpace: { _, _ in true }, processIdentity: { _ in safety.process() })
  try worker.queue.sync {
    let operation = DesktopOperation(timeout: 20)
    worker.setFrontmost(pid: app.pid)
    if scenario == "registration" {
      adapter.subroles[0] = kAXDialogSubrole
      failure { _ = try worker.capture(application: app, operation: operation) }
      expect(adapter.writes.isEmpty && store.entries.isEmpty, "A new dialog cannot acquire camera ownership")
      return
    }
    let selected = try worker.capture(application: app, operation: operation)
    try worker.commit(id: selected.id, operation: operation)
    if scenario == "user-minimized" || scenario == "position-only" {
      if scenario == "position-only" {
        adapter.positionWritable = true
        _ = try worker.panCamera(by: 5, display: display, operation: operation)
      }
      adapter.minimized[0] = true
      let writes = adapter.positionWrites.count
      if scenario == "position-only" {
        failure { _ = try worker.setCameraPaused(true, display: display, operation: operation) }
        expect(!store.entries.isEmpty, "Position-only ownership cannot authorize restoring an owner-minimized dialog")
      } else {
        _ = try worker.moveCamera(by: 1, display: display, operation: operation)
        expect(worker.state().windows[0].availability == .unavailable, "Unowned minimized dialogs cannot become candidates")
      }
      expect(adapter.writes.isEmpty && adapter.positionWrites.count == writes && adapter.minimized[0],
        "Unowned minimization must never receive a recovery write")
      return
    }
    _ = try worker.moveCamera(by: 1, display: display, operation: operation)
    expect(adapter.minimized[0] && adapter.writes.count == 1 && store.entries.count == 1,
      "A standard exact window must confirm its delivered park despite AppKit's minimized AXDialog subrole")
    if scenario == "restore" {
      adapter.afterRestore = { adapter.delayedStandardSubroleReads = 3 }
      _ = try worker.setCameraPaused(true, display: display, operation: operation)
      expect(adapter.delayedStandardSubroleReads == 0 && !adapter.minimized[0] && store.entries.isEmpty,
        "Owned parked-dialog recovery must wait for visible AXStandardWindow before releasing durable ownership")
      expect(adapter.writes.count == 2 && adapter.frames[0] == CGRect(x: 72, y: 110, width: 620, height: 470),
        "Parked-dialog recovery must restore the exact original once without retargeting a sibling")
      return
    }
    switch scenario {
    case "nil-subrole": adapter.parkedSubrole = nil
    case "other-subrole": adapter.parkedSubrole = kAXSystemDialogSubrole
    case "visible-dialog": adapter.minimized[0] = false; adapter.subroles[0] = kAXDialogSubrole
    case "missing-minimized": adapter.transientFailures[kAXMinimizedAttribute] = 1
    case "wrong-role": adapter.roles[0] = kAXSheetRole
    case "fullscreen": adapter.fullScreen[0] = true
    case "sheets": adapter.sheets = [adapter.foreign]
    case "membership": adapter.windows = [adapter.b, adapter.foreign]
    case "pid": adapter.reportedPID = 41099
    case "process": safety.replaceProcess()
    case "journal-missing": try store.complete(id: selected.id)
    case "journal-pid", "journal-process":
      try store.complete(id: selected.id)
      try store.prepare(DesktopCameraJournalEntry(id: selected.id,
        pid: scenario == "journal-pid" ? 41099 : app.pid,
        processIdentity: scenario == "journal-process" ? .init(seconds: 3, microseconds: 4) : birth,
        title: selected.title, appName: app.appName, bundleIdentifier: nil, originalFrame: selected.originalFrame))
    default: fatalError("Unknown parked-dialog scenario")
    }
    let writes = adapter.writes.count
    failure { _ = try worker.setCameraPaused(true, display: display, operation: operation) }
    expect(adapter.writes.count == writes && adapter.positionWrites.isEmpty,
      "\(scenario) cannot use the owned parked-dialog exception to send any native write")
    expect(worker.state().camera.paused && worker.state().camera.requiresRestoration,
      "Failed parked-dialog identity must retain recovery ownership")
  }
}
for scenario in ["restore", "registration", "user-minimized", "position-only", "nil-subrole", "other-subrole",
  "visible-dialog", "missing-minimized", "wrong-role", "fullscreen", "sheets", "membership", "pid", "process",
  "journal-missing", "journal-pid", "journal-process"] {
  try verifyOwnedParkedDialog(scenario)
}
print("Owned parked-dialog tests passed: explicit minimized state, exact retained handle/process/journal ownership, strict visible StandardWindow convergence, and all invalid-context refusals.")

final class ScalarCancellationAX: DesktopAXAccess {
  let adapter = CameraAX()
  var reads: [String] = []
  var afterRead: ((String) -> Void)?
  func application(pid: pid_t) -> AXUIElement { adapter.application(pid: pid) }
  func timeout(_ element: AXUIElement) -> Bool { adapter.timeout(element) }
  func pid(_ element: AXUIElement) -> pid_t? { adapter.pid(element) }
  func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    reads.append(name)
    let value = adapter.read(element, name)
    afterRead?(name)
    return value
  }
  func perform(_ element: AXUIElement, _ action: String) -> AXError { adapter.perform(element, action) }
  func mainSettable(_ element: AXUIElement) -> Bool { adapter.mainSettable(element) }
  func makeMain(_ element: AXUIElement) -> AXError { adapter.makeMain(element) }
}
let cancellationAttributes = [kAXRoleAttribute, kAXSubroleAttribute, "AXFullScreen", kAXMinimizedAttribute, "AXSheets"]
for cancelledAttribute in cancellationAttributes {
  let adapter = ScalarCancellationAX()
  let access: any DesktopAXAccess = adapter
  let operation = DesktopOperation(timeout: 10)
  adapter.afterRead = { if $0 == cancelledAttribute { operation.cancel() } }
  failure { _ = try access.readMultiple(adapter.adapter.a, cancellationAttributes, operation) }
  let last = cancellationAttributes.firstIndex(of: cancelledAttribute)!
  expect(adapter.reads == Array(cancellationAttributes.prefix(last + 1)),
    "Scalar cancellation after \(cancelledAttribute) must stop before the next native attribute IPC")
}
for expired in [false, true] {
  let adapter = ScalarCancellationAX()
  let access: any DesktopAXAccess = adapter
  let operation = DesktopOperation(timeout: expired ? 0 : 10)
  if !expired { operation.cancel() }
  failure { _ = try access.readMultiple(adapter.adapter.a, cancellationAttributes, operation) }
  expect(adapter.reads.isEmpty, "Cancelled or expired scalar operations must stop before the first native IPC")
}
let missingCancellationAX = ScalarCancellationAX()
let missingCancellation = DesktopOperation(timeout: 10)
missingCancellationAX.adapter.transientFailures[kAXRoleAttribute] = 1
missingCancellationAX.afterRead = { _ in missingCancellation.cancel() }
failure { _ = try missingCancellationAX.readMultiple(missingCancellationAX.adapter.a, cancellationAttributes, missingCancellation) }
expect(missingCancellationAX.reads == [kAXRoleAttribute], "A failed scalar read must still observe cancellation before the next IPC")
print("Scalar AX cancellation tests passed: cancelled/expired preflight, cancellation after each attribute, and missing-value cancellation stop the next native IPC.")
