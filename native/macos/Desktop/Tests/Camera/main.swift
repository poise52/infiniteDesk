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
  var writes: [(Int, Bool)] = []
  var positionWrites: [(Int, CGPoint)] = []
  var positionWritable = false
  var clampLeft = false
  var deferNextPosition = false
  var focusWrites = 0
  var focusOnRestore: AXUIElement?
  var afterRestore: (() -> Void)?
  var positionReads = 0
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
  func pid(_ element: AXUIElement) -> pid_t? { 41000 }
  func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
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
    case kAXRoleAttribute: return kAXWindowRole as CFString
    case kAXSubroleAttribute: return kAXStandardWindowSubrole as CFString
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
  for _ in 0..<200 { _ = try panBackend.panCamera(by: 0.125, display: display, operation: operation) }
  expect(panJournal.durableCommitCount == durable, "Continuous movement cannot fsync per input tick")
  expect(panAX.positionReads - readsBeforeTicks == 800, "Each visible window uses one candidate frame sample plus fresh post-write readback per batch")
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
func verifyUnparkFocus(takeover: Bool, foreign: Bool, active: Bool) throws {
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
    if takeover { adapter.afterRestore = { generation.advance() } }
    _ = try worker.panCamera(by: -1420, ended: true, display: display, operation: operation)
    let repairExpected = active && !takeover && !foreign
    expect(adapter.focusWrites == (repairExpected ? 1 : 0), "Only proven system displacement can trigger one sibling focus repair")
    if repairExpected {
      expect(CFEqual(adapter.focused!, adapter.b) && worker.state().focusedID == b.id, "Native auto-focus on arriving A must return to the exact previously focused B")
      adapter.focusOnRestore = nil
      _ = try worker.panCamera(by: 1, display: display, operation: operation)
      expect(adapter.focusWrites == 1, "Normal continuous position ticks must never perform focus actions")
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
