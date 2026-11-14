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
      var point = frames[index].origin
      if staleFrameReads > 0, !minimized[index] { staleFrameReads -= 1; point.x += 80 }
      return AXValueCreate(.cgPoint, &point)
    case kAXSizeAttribute:
      var size = frames[index].size
      return AXValueCreate(.cgSize, &size)
    default: return nil
    }
  }
  func perform(_ element: AXUIElement, _ action: String) -> AXError { focused = element; return .success }
  func mainSettable(_ element: AXUIElement) -> Bool { true }
  func makeMain(_ element: AXUIElement) -> AXError { focused = element; return .success }
  func settable(_ element: AXUIElement, _ name: String) -> Bool { writable && name == kAXMinimizedAttribute }
  func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> AXError {
    expect(!CFEqual(element, foreign), "Unregistered windows must never be mutated")
    expect(name == kAXMinimizedAttribute, "Page transitions must never write offscreen geometry")
    do { try beforeWrite?() } catch { fatalError("Missing durable recovery intent") }
    let state = value as! Bool
    writes.append((index(element), state))
    if refuse { return .failure }
    minimized[index(element)] = state
    transientFailures = failuresAfterNextWrite
    failuresAfterNextWrite = [:]
    if !state {
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
