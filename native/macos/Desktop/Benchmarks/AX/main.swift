import AppKit
@preconcurrency import ApplicationServices
import Darwin
import Foundation

enum BenchError: LocalizedError {
  case failure(String)
  var errorDescription: String? { switch self { case .failure(let text): return text } }
}

struct Options {
  var counts = [2, 4, 8]
  var samples = 120
  var edgeSamples = 20
  var output: String?
  var label = "unknown"
  init(_ arguments: [String]) throws {
    var index = 0
    while index < arguments.count {
      let key = arguments[index]
      guard index + 1 < arguments.count else { throw BenchError.failure("Missing value for \(key)") }
      let value = arguments[index + 1]
      switch key {
      case "--counts":
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        let parsed = parts.compactMap { Int($0) }
        guard parsed.count == parts.count, !parsed.isEmpty, parsed.allSatisfy({ (1...16).contains($0) }), Set(parsed).count == parsed.count else {
          throw BenchError.failure("Counts must be distinct integers in 1...16")
        }
        counts = parsed
      case "--samples":
        guard let parsed = Int(value), (20...1000).contains(parsed), parsed.isMultiple(of: 2) else {
          throw BenchError.failure("Samples must be even and in 20...1000")
        }
        samples = parsed
      case "--edge-samples":
        guard let parsed = Int(value), (0...1000).contains(parsed), parsed.isMultiple(of: 2) else {
          throw BenchError.failure("Edge samples must be even and in 0...1000; zero disables all edge work")
        }
        edgeSamples = parsed
      case "--output":
        guard value.hasPrefix("/") else { throw BenchError.failure("Output must be absolute") }
        output = value
      case "--label": label = value
      default: throw BenchError.failure("Unknown argument \(key)")
      }
      index += 2
    }
  }
}

struct Calls: Codable {
  var reads = 0
  var multipleReads = 0
  var requestedAttributes = 0
  var positionWrites = 0
  var parkWrites = 0
  var unparkWrites = 0
  var settable = 0
  var actions = 0
  var guardPIDChecks = 0
  var denied = 0
}

struct AXDiagnostic: Codable {
  let method: String
  let lastMutation: String
  let returnedSubrole: String?
  let returnedTypeID: UInt?
  let status: Int32
  let role: String?
  let minimized: Bool?
  let fullScreen: Bool?
  let handleInApplicationWindows: Bool?
  let pid: pid_t?
  let processIdentity: DesktopProcessIdentity?
}

// AX handles and counters are used only from the production backend's serial queue.
final class GuardedAX: DesktopCameraAXAccess {
  let target: pid_t
  let base = SystemDesktopAXAccess()
  var calls = Calls()
  var diagnostics: [AXDiagnostic] = []
  var lastMutation = "none"
  private func diagnoseSubrole(_ value: CFTypeRef?, element: AXUIElement, status: AXError, method: String, operation: DesktopOperation? = nil) throws {
    guard status != .success || value as? String != kAXStandardWindowSubrole else { return }
    var rawStatus = status.rawValue
    if let value, CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
      var error = AXError.success
      if AXValueGetValue(value as! AXValue, .axError, &error) { rawStatus = error.rawValue }
    }
    let raw = value as? String
    let type = value.map { UInt(CFGetTypeID($0)) }
    if let last = diagnostics.last, last.method == method, last.lastMutation == lastMutation,
      last.returnedSubrole == raw, last.returnedTypeID == type, last.status == rawStatus { return }
    let app = base.application(pid: target)
    // Extra diagnostic IPC occurs only after identity validation has already failed.
    func diagnosticRead(_ source: AXUIElement, _ name: String) throws -> CFTypeRef? {
      try operation?.check()
      let value = base.read(source, name)
      try operation?.check()
      return value
    }
    let role = try diagnosticRead(element, kAXRoleAttribute) as? String
    let minimized = try diagnosticRead(element, kAXMinimizedAttribute) as? Bool
    let fullScreen = try diagnosticRead(element, "AXFullScreen") as? Bool
    let windows = try diagnosticRead(app, kAXWindowsAttribute) as? [AXUIElement]
    try operation?.check()
    let actualPID = base.pid(element)
    try operation?.check()
    calls.reads += 4; calls.requestedAttributes += 4
    if diagnostics.count == 32 { diagnostics.removeFirst() }
    diagnostics.append(AXDiagnostic(method: method, lastMutation: lastMutation,
      returnedSubrole: raw, returnedTypeID: type, status: rawStatus,
      role: role, minimized: minimized, fullScreen: fullScreen,
      handleInApplicationWindows: windows.map { $0.contains { CFEqual($0, element) } },
      pid: actualPID, processIdentity: DesktopProcessIdentity.read(pid: target)))
  }
  init(target: pid_t) { self.target = target }
  private func permits(_ element: AXUIElement) -> Bool {
    calls.guardPIDChecks += 1
    guard base.pid(element) == target else { calls.denied += 1; return false }
    return true
  }
  func application(pid: pid_t) -> AXUIElement {
    precondition(pid == target, "Benchmark must never access another application")
    return base.application(pid: pid)
  }
  func timeout(_ element: AXUIElement) -> Bool { permits(element) && base.timeout(element) }
  func pid(_ element: AXUIElement) -> pid_t? { permits(element) ? target : nil }
  func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    try? checkedRead(element, name, operation: nil)
  }
  private func checkedRead(_ element: AXUIElement, _ name: String, operation: DesktopOperation?) throws -> CFTypeRef? {
    try operation?.check()
    let permitted = permits(element)
    try operation?.check()
    guard permitted else { return nil }
    calls.reads += 1; calls.requestedAttributes += 1
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    try operation?.check()
    if name == kAXSubroleAttribute {
      try diagnoseSubrole(value, element: element, status: status, method: "single", operation: operation)
    }
    return status == .success ? value : nil
  }
  // This additional method also compiles against the pre-batching baseline protocol.
  func readMultiple(_ element: AXUIElement, _ names: [String], _ operation: DesktopOperation) throws -> [CFTypeRef?] {
    #if DESKTOP_AX_BATCH_EXPERIMENT
    try operation.check()
    let permitted = permits(element)
    try operation.check()
    guard permitted else { return Array(repeating: nil, count: names.count) }
    calls.multipleReads += 1; calls.requestedAttributes += names.count
    var result: CFArray?
    let status = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &result)
    try operation.check()
    guard status == .success, let values = result as? [CFTypeRef], values.count == names.count else {
      if names.contains(kAXSubroleAttribute) { try diagnoseSubrole(nil, element: element, status: status, method: "multiple", operation: operation) }
      return Array(repeating: nil, count: names.count)
    }
    if let index = names.firstIndex(of: kAXSubroleAttribute) {
      try diagnoseSubrole(values[index], element: element, status: status, method: "multiple", operation: operation)
    }
    return values.map { value in
      if CFGetTypeID(value) == CFNullGetTypeID() { return nil }
      if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
      return value
    }
    #else
    return try names.map { try checkedRead(element, $0, operation: operation) }
    #endif
  }
  func perform(_ element: AXUIElement, _ action: String) -> AXError {
    guard permits(element) else { return .illegalArgument }
    calls.actions += 1; return base.perform(element, action)
  }
  func mainSettable(_ element: AXUIElement) -> Bool { permits(element) && base.mainSettable(element) }
  func makeMain(_ element: AXUIElement) -> AXError {
    guard permits(element) else { return .illegalArgument }
    calls.actions += 1; return base.makeMain(element)
  }
  func settable(_ element: AXUIElement, _ name: String) -> Bool {
    guard permits(element) else { return false }
    calls.settable += 1; return base.settable(element, name)
  }
  func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> AXError {
    guard permits(element) else { return .illegalArgument }
    guard name == kAXPositionAttribute || name == kAXMinimizedAttribute else { calls.denied += 1; return .illegalArgument }
    if name == kAXPositionAttribute { calls.positionWrites += 1 }
    else if value as? Bool == true { calls.parkWrites += 1 }
    else { calls.unparkWrites += 1 }
    if name == kAXMinimizedAttribute { lastMutation = value as? Bool == true ? "park" : "unpark" }
    return base.set(element, name, value)
  }
}

final class NoObserver: DesktopObservationProvider {
  func create(pid: pid_t, receive: @escaping @Sendable (DesktopObservationEvent) -> Void) throws -> any DesktopAXObserverHandle {
    throw BenchError.failure("Isolated benchmark excludes observation delivery")
  }
}

func residentBytes(_ pid: pid_t) -> UInt64? {
  var info = proc_taskinfo()
  let size = MemoryLayout<proc_taskinfo>.stride
  guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size)) == size else { return nil }
  return info.pti_resident_size
}

struct Sample: Codable {
  let phase: String
  let kind: String
  let milliseconds: Double
  let calls: Calls
}
struct Distribution: Encodable {
  let count: Int
  let p50MS: Double?
  let p95MS: Double?
  let p99MS: Double?
  enum CodingKeys: String, CodingKey { case count, p50MS, p95MS, p99MS }
  func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(count, forKey: .count)
    try values.encode(p50MS, forKey: .p50MS)
    try values.encode(p95MS, forKey: .p95MS)
    try values.encode(p99MS, forKey: .p99MS)
  }
  init(_ samples: [Double]) {
    let sorted = samples.sorted()
    count = sorted.count
    func percentile(_ fraction: Double) -> Double? {
      sorted.isEmpty ? nil : sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }
    p50MS = percentile(0.50); p95MS = percentile(0.95); p99MS = percentile(0.99)
  }
}
struct FailedWindow: Encodable {
  let id: UUID
  let pid: pid_t
  let availability: String
  let observationDetail: String?
  let managerMinimized: Bool
  let originalFrame: CGRect
  let worldFrame: CGRect
  init(_ window: DesktopWindow) {
    id = window.id; pid = window.pid; availability = window.availability.rawValue
    observationDetail = window.observationDetail; managerMinimized = window.managerMinimized
    originalFrame = window.originalFrame; worldFrame = window.worldFrame
  }
}
struct FailedBatch: Encodable {
  let phase: String
  let delta: CGFloat
  let milliseconds: Double
  let calls: Calls
  let cameraPaused: Bool
  let cameraDetail: String?
  let cameraOrigin: CGPoint
  let windows: [FailedWindow]
  init(phase: String, delta: CGFloat, milliseconds: Double, calls: Calls, state: DesktopBackendState) {
    self.phase = phase; self.delta = delta; self.milliseconds = milliseconds; self.calls = calls
    cameraPaused = state.camera.paused; cameraDetail = state.camera.detail; cameraOrigin = state.camera.origin
    windows = state.windows.map(FailedWindow.init)
  }
}
struct Run: Encodable {
  let windows: Int
  var status = "running"
  var error: String?
  var foregroundInterference = false
  var cleanupRestored = false
  var accessorResidentBefore: UInt64?
  var accessorResidentAfter: UInt64?
  var fixtureResidentBefore: UInt64?
  var fixtureResidentAfter: UInt64?
  var samples: [Sample] = []
  var axDiagnostics: [AXDiagnostic] = []
  var failedBatch: FailedBatch?
  var distributions: [String: Distribution] {
    Dictionary(uniqueKeysWithValues: ["normal", "park", "unpark"].map { kind in
      (kind, Distribution(samples.filter { $0.kind == kind }.map(\.milliseconds)))
    })
  }
  enum CodingKeys: String, CodingKey {
    case windows, status, error, foregroundInterference, cleanupRestored, accessorResidentBefore, accessorResidentAfter, fixtureResidentBefore, fixtureResidentAfter, samples, distributions, axDiagnostics, failedBatch
  }
  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(windows, forKey: .windows); try c.encode(status, forKey: .status)
    try c.encodeIfPresent(error, forKey: .error); try c.encode(foregroundInterference, forKey: .foregroundInterference)
    try c.encode(cleanupRestored, forKey: .cleanupRestored)
    try c.encodeIfPresent(accessorResidentBefore, forKey: .accessorResidentBefore)
    try c.encodeIfPresent(accessorResidentAfter, forKey: .accessorResidentAfter)
    try c.encodeIfPresent(fixtureResidentBefore, forKey: .fixtureResidentBefore)
    try c.encodeIfPresent(fixtureResidentAfter, forKey: .fixtureResidentAfter)
    try c.encodeIfPresent(failedBatch, forKey: .failedBatch)
    try c.encode(axDiagnostics, forKey: .axDiagnostics)
    try c.encode(samples, forKey: .samples); try c.encode(distributions, forKey: .distributions)
  }
}

struct BenchmarkBuildConfiguration: Codable, Equatable {
  let batchExperiment: Bool
  let readStrategy: String
  let swiftDefines: [String]
  static var compiled: Self {
    #if DESKTOP_AX_BATCH_EXPERIMENT
    Self(batchExperiment: true, readStrategy: "bulk-experiment", swiftDefines: ["DESKTOP_AX_BATCH_EXPERIMENT"])
    #else
    Self(batchExperiment: false, readStrategy: "scalar", swiftDefines: [])
    #endif
  }
}

struct Report: Encodable {
  let version = 1
  let label: String
  let timestamp = ISO8601DateFormatter().string(from: Date())
  let os = ProcessInfo.processInfo.operatingSystemVersionString
  let timing = "Wall time inside production backend.queue around synchronous panCamera; includes real native AX IPC, readback, journal fsync, snapshot publication, and PID guards. Excludes dispatch wait, input coalescing, observation delivery, rendering and compositor latency."
  let workload = "12 warm-up +/-2pt batches; measured alternating +/-2pt normal batches; When edgeSamples > 0, 4 warm-up and measured alternating +/-2*displayWidth park/unpark batches. edgeSamples=0 omits all edge work. Each edge direction has edgeSamples/2 batches. No synthetic input."
  let memory = "proc_pidinfo(PROC_PIDTASKINFO).pti_resident_size snapshots in bytes; accessor and fixture separate. RSS is not allocations, peak memory or WindowServer/GPU memory."
  let observation = "Disabled to isolate synchronous real AX worker batches; foreground and current-Space checks remain active."
  let requestedSamples: Int
  let requestedEdgeSamples: Int
  let sourceFingerprints: [String: String]
  let buildConfiguration: BenchmarkBuildConfiguration
  var status: String
  var reason: String?
  var runs: [Run]
}

final class FixtureSession {
  let process = Process()
  let input = Pipe()
  let output = Pipe()
  var buffer = Data()
  init(count: Int, nonce: String) throws {
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--fixture", nonce, String(count), String(getpid())]
    process.standardInput = input; process.standardOutput = output
    process.standardError = FileHandle.standardError
    try process.run()
    do {
      guard try line() == "ready \(nonce) \(process.processIdentifier)" else { throw BenchError.failure("Fixture identity handshake failed") }
    } catch { stop(); throw error }
  }
  func line() throws -> String {
    let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    while true {
      if let newline = buffer.firstIndex(of: 10) {
        let result = String(decoding: buffer[..<newline], as: UTF8.self)
        buffer.removeSubrange(...newline); return result
      }
      guard DispatchTime.now().uptimeNanoseconds < deadline else { throw BenchError.failure("Fixture IPC timed out") }
      var item = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
      let result = poll(&item, 1, 100)
      guard result >= 0 else { throw BenchError.failure("Fixture IPC poll failed") }
      if result > 0 {
        let data = output.fileHandleForReading.availableData
        guard !data.isEmpty else { throw BenchError.failure("Fixture exited") }
        buffer.append(data)
      }
    }
  }
  func focus(_ index: Int) throws {
    try input.fileHandleForWriting.write(contentsOf: Data("focus \(index)\n".utf8))
    guard try line() == "focused \(index)" else { throw BenchError.failure("Unexpected fixture response") }
  }
  func stop() {
    try? input.fileHandleForWriting.close()
    if process.isRunning { process.terminate() }
    let deadline = Date().addingTimeInterval(2)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }
  deinit { if process.isRunning { process.terminate() } }
}

@MainActor final class FixtureDelegate: NSObject, NSApplicationDelegate {
  let nonce: String
  let count: Int
  var windows: [NSWindow] = []
  var control: NSWindow?
  var pending = ""
  init(nonce: String, count: Int) { self.nonce = nonce; self.count = count }
  func reply(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let screen = NSScreen.screens.first else { NSApp.terminate(nil); return }
    let area = screen.visibleFrame
    let control = NSWindow(contentRect: NSRect(x: area.minX + 12, y: area.minY + 12, width: 200, height: 60),
      styleMask: [.titled], backing: .buffered, defer: false)
    control.title = "AXBench control \(nonce)"
    control.contentView = NSTextField(labelWithString: "Benchmark control; never registered")
    control.isReleasedWhenClosed = false
    control.orderFront(nil); self.control = control
    let columns = Int(ceil(sqrt(Double(count))))
    let rows = Int(ceil(Double(count) / Double(columns)))
    let cellWidth = (area.width - 40) / CGFloat(columns)
    let cellHeight = (area.height - 40) / CGFloat(rows)
    for index in 0..<count {
      let width = min(480, cellWidth - 28)
      let height = min(300, cellHeight - 52)
      let frame = NSRect(x: area.minX + 34 + CGFloat(index % columns) * cellWidth,
                         y: area.minY + 34 + CGFloat(index / columns) * cellHeight,
                         width: width, height: height)
      let window = NSWindow(contentRect: frame, styleMask: [.titled, .miniaturizable, .resizable], backing: .buffered, defer: false)
      window.title = "AXBench \(nonce) \(index)"
      window.isReleasedWhenClosed = false
      window.contentView = NSTextField(labelWithString: "Disposable real AX window \(index + 1)/\(count)")
      window.orderFront(nil); windows.append(window)
    }
    windows.last?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    FileHandle.standardInput.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if data.isEmpty { NSApp.terminate(nil); return }
        self.pending += String(decoding: data, as: UTF8.self)
        while let newline = self.pending.firstIndex(of: "\n") {
          let command = String(self.pending[..<newline]); self.pending.removeSubrange(...newline)
          let parts = command.split(separator: " ")
          guard parts.count == 2, parts[0] == "focus", let index = Int(parts[1]), self.windows.indices.contains(index) else {
            self.reply("invalid"); continue
          }
          self.windows[index].makeKeyAndOrderFront(nil)
          NSApp.activate(ignoringOtherApps: true); self.reply("focused \(index)")
        }
      }
    }
    reply("ready \(nonce) \(getpid())")
  }
}

@MainActor func measure(count: Int, samples: Int, edgeSamples: Int, display: DesktopCameraDisplay) -> Run {
  var result = Run(windows: count)
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("infinitedesk-ax-bench-\(UUID())")
  var fixture: FixtureSession?
  var backend: DesktopWindowBackend?
  var access: GuardedAX?
  do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let nonce = UUID().uuidString
    let child = try FixtureSession(count: count, nonce: nonce)
    fixture = child
    let pid = child.process.processIdentifier
    guard let identity = DesktopProcessIdentity.read(pid: pid) else { throw BenchError.failure("Fixture process identity unavailable") }
    let ax = GuardedAX(target: pid)
    access = ax
    let journal = try DesktopCameraJournal(fileURL: directory.appendingPathComponent("recovery.json"))
    let worker = DesktopWindowBackend(access: ax, observationProvider: NoObserver(), cameraJournal: journal)
    backend = worker
    let application = DesktopApplicationSnapshot(pid: pid, launchDate: NSRunningApplication(processIdentifier: pid)?.launchDate,
      appName: "AX Benchmark Fixture", bundleIdentifier: Bundle.main.bundleIdentifier, processIdentity: identity)
    let activationDeadline = Date().addingTimeInterval(2)
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
      guard Date() < activationDeadline else { throw BenchError.failure("Disposable fixture did not become foreground") }
      Thread.sleep(forTimeInterval: 0.01)
    }
    for index in 0..<count {
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        result.foregroundInterference = true
        throw BenchError.failure("Foreground changed during fixture registration")
      }
      try child.focus(index)
      try worker.queue.sync {
        let app = ax.application(pid: pid)
        let deadline = DispatchTime.now() + .seconds(3)
        var previousFrame: CGRect?
        var stableFrames = 0
        while stableFrames < 3 {
          if let focused = ax.read(app, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID(),
            ax.read(focused as! AXUIElement, kAXTitleAttribute) as? String == "AXBench \(nonce) \(index)",
            let position = ax.read(focused as! AXUIElement, kAXPositionAttribute),
            let size = ax.read(focused as! AXUIElement, kAXSizeAttribute),
            CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
            AXValueGetType(position as! AXValue) == .cgPoint, AXValueGetType(size as! AXValue) == .cgSize {
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            if AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) {
              let frame = CGRect(origin: point, size: dimensions)
              if desktopWindowOnCurrentSpace(pid: pid, frame: frame) {
                stableFrames = previousFrame.map { desktopFramesEqual($0, frame, tolerance: 0.01) } == true ? stableFrames + 1 : 1
                previousFrame = frame
              } else { stableFrames = 0; previousFrame = nil }
            } else { stableFrames = 0; previousFrame = nil }
          } else { stableFrames = 0; previousFrame = nil }
          guard DispatchTime.now() < deadline else {
            throw BenchError.failure("Fixture window \(index) did not expose stable focused AX bounds matching exactly one on-screen CG window")
          }
          if stableFrames < 3 { Thread.sleep(forTimeInterval: 0.02) }
        }
        worker.setFrontmost(pid: pid)
        let operation = DesktopOperation()
        let captured = try worker.capture(application: application, operation: operation)
        guard desktopWindowOnCurrentSpace(pid: pid, frame: captured.originalFrame) else {
          throw BenchError.failure("Fixture window \(index) lost its exact current-Space frame during capture")
        }
        try worker.commit(id: captured.id, operation: operation)
      }
    }
    try worker.queue.sync {
      _ = try worker.panCamera(by: 0, ended: true, display: display, operation: DesktopOperation())
      let state = worker.state()
      guard state.windows.count == count, state.windows.allSatisfy({
        $0.availability == .available && !$0.managerMinimized && desktopWindowOnCurrentSpace(pid: pid, frame: $0.originalFrame)
      }) else {
        throw BenchError.failure("Fixture setup rejected one or more originals before warm-up")
      }
    }
    result.accessorResidentBefore = residentBytes(getpid()); result.fixtureResidentBefore = residentBytes(pid)
    func batch(_ delta: CGFloat, phase: String, retain: Bool) throws {
      guard DesktopCameraDisplay.current() == display else { throw BenchError.failure("Display configuration changed") }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        result.foregroundInterference = true; throw BenchError.failure("Foreground changed; benchmark aborted without taking it back")
      }
      let sample = try worker.queue.sync {
        ax.calls = Calls()
        let start = DispatchTime.now().uptimeNanoseconds
        do {
          let state = try worker.panCamera(by: delta, display: display, operation: DesktopOperation(timeout: 15))
          let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
          guard !state.paused, state.detail == nil, ax.calls.denied == 0 else { throw BenchError.failure(state.detail ?? "AX access guard rejected a call") }
          let kind = ax.calls.parkWrites > 0 ? "park" : ax.calls.unparkWrites > 0 ? "unpark" : "normal"
          guard phase != "normal" || (kind == "normal" && ax.calls.positionWrites == count) else {
            throw BenchError.failure("Normal batch did not move every visible original")
          }
          guard phase != "edge" || ((kind == "park" && ax.calls.parkWrites == count) || (kind == "unpark" && ax.calls.unparkWrites == count)) else {
            throw BenchError.failure("Edge batch did not park/unpark every original")
          }
          return Sample(phase: phase, kind: kind, milliseconds: elapsed, calls: ax.calls)
        } catch {
          let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
          let failure = FailedBatch(phase: phase, delta: delta, milliseconds: elapsed, calls: ax.calls, state: worker.state())
          result.failedBatch = failure
          let diagnostic = String(decoding: try JSONEncoder().encode(failure), as: UTF8.self)
          throw BenchError.failure(error.localizedDescription + "; failedBatch=" + diagnostic)
        }
      }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        result.foregroundInterference = true; throw BenchError.failure("Foreground changed during measured batch")
      }
      guard DesktopCameraDisplay.current() == display else { throw BenchError.failure("Display configuration changed during measured batch") }
      if retain { result.samples.append(sample) }
    }
    for index in 0..<12 { try batch(index.isMultiple(of: 2) ? 2 : -2, phase: "normal", retain: false) }
    for index in 0..<samples { try batch(index.isMultiple(of: 2) ? 2 : -2, phase: "normal", retain: true) }
    if edgeSamples > 0 {
      for index in 0..<4 { try batch(index.isMultiple(of: 2) ? display.frame.width * 2 : -display.frame.width * 2, phase: "edge", retain: false) }
    }
    for index in 0..<edgeSamples { try batch(index.isMultiple(of: 2) ? display.frame.width * 2 : -display.frame.width * 2, phase: "edge", retain: true) }
    result.accessorResidentAfter = residentBytes(getpid()); result.fixtureResidentAfter = residentBytes(pid)
    result.status = "passed"
  } catch {
    result.status = "failed"; result.error = error.localizedDescription
    if result.failedBatch == nil, let backend, let access {
      result.failedBatch = backend.queue.sync {
        FailedBatch(phase: "setup-or-post-batch-check", delta: 0, milliseconds: 0, calls: access.calls, state: backend.state())
      }
    }
  }
  if let backend {
    do {
      try backend.queue.sync {
        _ = try backend.setCameraPaused(true, display: display, operation: DesktopOperation(timeout: 15))
        guard !backend.state().camera.requiresRestoration else { throw BenchError.failure("Restoration remains pending") }
      }
      result.cleanupRestored = true
    } catch { result.status = "failed"; result.error = (result.error.map { $0 + "; " } ?? "") + "Cleanup: " + error.localizedDescription }
  }
  if let backend, let access { result.axDiagnostics = backend.queue.sync { access.diagnostics } }
  fixture?.stop()
  if result.cleanupRestored || backend == nil { try? FileManager.default.removeItem(at: directory) }
  else { result.error = (result.error ?? "") + "; isolated recovery evidence: " + directory.path }
  return result
}

@MainActor func main() throws {
  let arguments = Array(CommandLine.arguments.dropFirst())
  if arguments.first == "--self-test" {
    guard arguments.count == 1 else { throw BenchError.failure("Unexpected self-test arguments") }
    let distribution = Distribution((1...100).map(Double.init))
    guard distribution.p50MS == 50, distribution.p95MS == 95, distribution.p99MS == 99,
      Distribution([]).p50MS == nil, try Options(["--counts", "2,5,10"]).counts == [2,5,10],
      try Options(["--edge-samples", "2"]).edgeSamples == 2,
      try Options(["--edge-samples", "0"]).edgeSamples == 0 else {
      throw BenchError.failure("Statistics/options self-test failed")
    }
    let emptyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Distribution([]))) as? [String: Any]
    guard emptyJSON?["p99MS"] is NSNull else { throw BenchError.failure("Empty distribution must encode null") }
    for invalid in [["--counts", "0"], ["--counts", "2,,4"], ["--counts", "2,2"], ["--samples", "21"], ["--edge-samples", "-2"], ["--edge-samples", "1"], ["--edge-samples", "3"], ["--output", "relative"], ["--unknown", "x"]] {
      do { _ = try Options(invalid) } catch { continue }
      throw BenchError.failure("Invalid option accepted: \(invalid)")
    }
    let cancelled = DesktopOperation()
    cancelled.cancel()
    let accessor = GuardedAX(target: getpid())
    let element = AXUIElementCreateApplication(getpid())
    do {
      _ = try accessor.readMultiple(element, [kAXRoleAttribute, kAXSubroleAttribute], cancelled)
      throw BenchError.failure("Cancelled attribute read was accepted")
    } catch is DesktopWindowError {}
    guard accessor.calls.reads == 0, accessor.calls.multipleReads == 0, accessor.calls.guardPIDChecks == 0 else {
      throw BenchError.failure("Cancelled attribute read reached native access")
    }
    print("AX benchmark headless self-test passed; readStrategy=\(BenchmarkBuildConfiguration.compiled.readStrategy) (no AppKit session or permission API invoked)")
    return
  }
  if arguments.first == "--fixture" {
    guard arguments.count == 4, UUID(uuidString: arguments[1]) != nil,
      let count = Int(arguments[2]), (1...16).contains(count), let parent = Int32(arguments[3]), parent == getppid() else {
      throw BenchError.failure("Fixture requires its direct benchmark parent and session UUID")
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = FixtureDelegate(nonce: arguments[1], count: count)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
    return
  }
  guard arguments.first == "--run" else { throw BenchError.failure("Use --self-test or --run --output /absolute/report.json [--counts 2,4,8] [--samples 120] [--edge-samples 20] [--label REV]") }
  let options = try Options(Array(arguments.dropFirst()))
  guard let output = options.output else { throw BenchError.failure("--output is required") }
  guard Bundle.main.bundleIdentifier == "org.infinitedesk.tests.ax-benchmark" else { throw BenchError.failure("Launch the dedicated benchmark app") }
  guard let manifestURL = Bundle.main.url(forResource: "source-fingerprints", withExtension: "json") else {
    throw BenchError.failure("Missing build provenance")
  }
  let fingerprints = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))
  guard let configurationURL = Bundle.main.url(forResource: "build-configuration", withExtension: "json") else {
    throw BenchError.failure("Missing build configuration provenance")
  }
  let configuration = try JSONDecoder().decode(BenchmarkBuildConfiguration.self, from: Data(contentsOf: configurationURL))
  guard configuration == BenchmarkBuildConfiguration.compiled else { throw BenchError.failure("Build configuration does not match this executable") }
  var report = Report(label: options.label, requestedSamples: options.samples,
    requestedEdgeSamples: options.edgeSamples, sourceFingerprints: fingerprints, buildConfiguration: configuration, status: "skipped", runs: [])
  var exitCode: Int32 = 77
  if !AXIsProcessTrusted() { report.reason = "Dedicated benchmark app lacks Accessibility permission; no permission prompt requested" }
  else if let display = DesktopCameraDisplay.current() {
    for count in options.counts {
      let run = measure(count: count, samples: options.samples, edgeSamples: options.edgeSamples, display: display)
      report.runs.append(run)
      if run.status != "passed" { break }
    }
    report.status = report.runs.allSatisfy { $0.status == "passed" } ? "passed" : "failed"
    exitCode = report.status == "passed" ? 0 : 1
  } else { report.reason = "Exactly one display is required" }
  let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  try encoder.encode(report).write(to: URL(fileURLWithPath: output), options: .atomic)
  print("\(report.status): \(output)")
  Darwin.exit(exitCode)
}

do { try main() }
catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); Darwin.exit(1) }
