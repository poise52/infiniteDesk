import AppKit
@preconcurrency import ApplicationServices
import CoreImage
import CoreMedia
import Darwin
import ScreenCaptureKit

enum AXRectResult: Sendable {
  case rect(CGRect, Int)
  case failure(String)
}
func fixtureAXRect(_ pid: pid_t) -> AXRectResult {
  let system = AXUIElementCreateSystemWide()
  let timeoutError = AXUIElementSetMessagingTimeout(system, 0.15)
  guard timeoutError == .success else {
    return .failure("timeout setup AX error \(timeoutError.rawValue)")
  }
  let app = AXUIElementCreateApplication(pid)
  var value: CFTypeRef?
  let windowsError = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
  guard windowsError == .success else {
    return .failure("windows AX error \(windowsError.rawValue)")
  }
  guard let windows = value as? [AXUIElement] else { return .failure("windows value invalid") }
  var identifiers: [String?] = []
  for (index, window) in windows.enumerated() {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(window, kAXIdentifierAttribute as CFString, &value)
    if error == .noValue || error == .attributeUnsupported {
      identifiers.append(nil)
      continue
    }
    guard error == .success else {
      return .failure(
        "window[\(index)] identifier AX error \(error.rawValue); windows=\(windows.count)")
    }
    guard let identifier = value as? String else {
      return .failure("window[\(index)] identifier value invalid; windows=\(windows.count)")
    }
    identifiers.append(identifier)
  }
  let selected: AXUIElement
  switch selectFixtureAXWindow(identifiers) {
  case .main(let index): selected = windows[index]
  case .missing: return .failure("main candidates=0; AX windows=\(windows.count)")
  case .duplicate(let count):
    return .failure("main candidates=\(count); AX windows=\(windows.count)")
  case .childPresent: return .failure("fixture child window present; AX windows=\(windows.count)")
  }
  var childrenValue: CFTypeRef?
  let childrenError = AXUIElementCopyAttributeValue(
    selected, kAXChildrenAttribute as CFString, &childrenValue)
  guard childrenError == .success else {
    return .failure("children AX error \(childrenError.rawValue)")
  }
  guard let children = childrenValue as? [AXUIElement] else {
    return .failure("children value invalid")
  }
  for child in children {
    var role: CFTypeRef?
    let roleError = AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
    guard roleError == .success else {
      return .failure("child role AX error \(roleError.rawValue)")
    }
    guard let roleName = role as? String else { return .failure("child role value invalid") }
    if roleName == kAXSheetRole as String || roleName == kAXDrawerRole as String
      || roleName == kAXWindowRole as String
    {
      return .failure("sheet, drawer or child window present")
    }
  }
  var position: CFTypeRef?
  var size: CFTypeRef?
  let positionError = AXUIElementCopyAttributeValue(
    selected, kAXPositionAttribute as CFString, &position)
  guard positionError == .success else {
    return .failure("position AX error \(positionError.rawValue)")
  }
  let sizeError = AXUIElementCopyAttributeValue(selected, kAXSizeAttribute as CFString, &size)
  guard sizeError == .success else { return .failure("size AX error \(sizeError.rawValue)") }
  guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
    CFGetTypeID(size) == AXValueGetTypeID()
  else { return .failure("position or size value invalid") }
  var origin = CGPoint.zero
  var dimensions = CGSize.zero
  guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
    AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
  else { return .failure("position or size conversion failed") }
  return .rect(CGRect(origin: origin, size: dimensions), windows.count)
}

// One readiness notification owns the read until its result is delivered on the main actor.
final class FixturePipeRead: @unchecked Sendable {
  enum ReadResult {
    case ignored
    case data(Data)
    case end(Int32?)
  }
  private let lock = NSLock()
  private var pending = false
  func read(_ handle: FileHandle) -> ReadResult {
    lock.lock()
    defer { lock.unlock() }
    guard !pending else { return .ignored }
    pending = true
    var bytes = [UInt8](repeating: 0, count: 129)
    var count: Int
    repeat {
      count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
    } while count < 0 && errno == EINTR
    if count > 0 { return .data(Data(bytes.prefix(count))) }
    return .end(count < 0 ? errno : nil)
  }
  func delivered() {
    lock.lock()
    pending = false
    lock.unlock()
  }
}

struct FrameInfo {
  let buffer: CVPixelBuffer
  let content: CGRect
  let screen: CGRect
  let scale: CGFloat
  let contentScale: CGFloat
}
// Callback state is protected by lock; pixel buffers are only transferred under it.
final class LatestFrame: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var latest: FrameInfo?
  private var dropped = 0
  private var activity: TimeInterval?
  private var error: String?
  func invalidate(_ reason: String) {
    lock.lock()
    error = reason
    latest = nil
    activity = nil
    lock.unlock()
  }
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    invalidate(error.localizedDescription)
  }
  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen else { return }
    guard CMSampleBufferIsValid(sampleBuffer),
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let info = attachments.first, let rawStatus = info[.status] as? Int
    else {
      invalidate("Missing frame status")
      return
    }
    if rawStatus != SCFrameStatus.complete.rawValue {
      if rawStatus == SCFrameStatus.idle.rawValue {
        lock.lock()
        activity = ProcessInfo.processInfo.systemUptime
        lock.unlock()
      } else {
        invalidate("Frame unavailable (status \(rawStatus))")
      }
      return
    }
    guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
      validFrame(
        width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
        rowBytes: CVPixelBufferGetBytesPerRow(buffer), status: rawStatus),
      let contentDict = info[.contentRect] as? [String: Any],
      let screenDict = info[.screenRect] as? [String: Any],
      let content = CGRect(dictionaryRepresentation: contentDict as CFDictionary),
      let screen = CGRect(dictionaryRepresentation: screenDict as CFDictionary),
      let scale = info[.scaleFactor] as? CGFloat,
      let contentScale = info[.contentScale] as? CGFloat,
      scale.isFinite, scale > 0, contentScale.isFinite, contentScale > 0,
      content.width > 0, content.height > 0, screen.width > 0, screen.height > 0
    else {
      invalidate("Invalid frame metadata")
      return
    }
    lock.lock()
    if latest != nil { dropped += 1 }
    latest = FrameInfo(
      buffer: buffer, content: content, screen: screen, scale: scale, contentScale: contentScale)
    activity = ProcessInfo.processInfo.systemUptime
    lock.unlock()
  }
  func take() -> (FrameInfo?, Int, String?, TimeInterval?)? {
    guard lock.try() else { return nil }
    defer { lock.unlock() }
    let frame = latest
    latest = nil
    let pendingError = error
    error = nil
    return (frame, dropped, pendingError, activity)
  }
}
final class Canvas: NSView {
  var image: CGImage?
  var sourceRect = CGRect.zero
  var zoom: CGFloat = 1
  var pan = CGPoint(x: 20, y: 20)
  var displaySize = CGSize.zero
  var input: ((CGEventType, CGPoint?) -> Void)?
  var keyboard: ((NSEvent, Bool) -> Void)?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  var imageRect: CGRect {
    CGRect(x: pan.x, y: pan.y, width: displaySize.width * zoom, height: displaySize.height * zoom)
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.darkGray.setFill()
    bounds.fill()
    guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
    let r = imageRect
    ctx.saveGState()
    ctx.translateBy(x: r.minX, y: r.maxY)
    ctx.scaleBy(x: r.width / CGFloat(image.width), y: -r.height / CGFloat(image.height))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    ctx.restoreGState()
  }
  func forward(_ event: NSEvent, _ type: CGEventType) {
    let point = mappedPoint(
      convert(event.locationInWindow, from: nil), imageRect: imageRect, sourceRect: sourceRect)
    if point != nil || type == .leftMouseUp { input?(type, point) }
  }
  override func mouseDown(with e: NSEvent) {
    window?.makeFirstResponder(self)
    forward(e, .leftMouseDown)
  }
  override func mouseDragged(with e: NSEvent) { forward(e, .leftMouseDragged) }
  override func mouseUp(with e: NSEvent) { forward(e, .leftMouseUp) }
  override func rightMouseDragged(with e: NSEvent) {
    pan.x += e.deltaX
    pan.y += e.deltaY
    needsDisplay = true
  }
  override func keyDown(with e: NSEvent) { keyboard?(e, true) }
  override func keyUp(with e: NSEvent) { keyboard?(e, false) }
}
@MainActor final class ProbeDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  let status = NSTextField(wrappingLabelWithString: "")
  let canvas = Canvas(frame: .zero)
  var output: LatestFrame?
  let context = CIContext(options: nil)
  let captureQueue = DispatchQueue(label: "stage6.capture")
  let axQueue = DispatchQueue(label: "stage6.ax")
  var fixture: Process?
  var fixtureReader: FileHandle?
  var fixturePipeRead: FixturePipeRead?
  var fixtureGeneration = 0
  var handshake: FixtureHandshake?
  var stream: SCStream?
  var targetWindow: SCWindow?
  var timer: Timer?
  weak var inputButton: NSButton?
  var inputEnabled = false {
    didSet {
      if oldValue && !inputEnabled { axCheck.invalidate() }
      inputButton?.title = inputEnabled ? "Input ON" : "Input OFF"
    }
  }
  var geometryOK = false
  var lastStreamActivity: TimeInterval?
  var session = SessionState()
  var starting = false
  var stopping = false
  var unknownStream: SCStream?
  var unknownOutput: LatestFrame?
  var terminatePending = false
  var pressed = PressedState()
  var axCheck = AXCheckState()
  var lastAXRect: CGRect?
  var axDiagnostic = "not requested"
  var frameDiagnostic = "frame unavailable"
  var axWindowCount = 0
  var postedMouseEvents: UInt64 = 0
  var lastMouseDown: CGPoint?
  var lastMouseUp: CGPoint?
  enum MouseMode { case cg, appKitGlobal, appKitNative, appKitLocalCG }
  var mouseMode: MouseMode = .cg
  var mouseConstruction = "CG"
  var mouseEventNumber = 0
  func applicationDidFinishLaunching(_ notification: Notification) {
    window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 1100, height: 800),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "InfiniteDesk Stage 6 Probe — experimental"
    window.isReleasedWhenClosed = false
    let root = NSView(frame: window.contentView!.bounds)
    root.autoresizingMask = [.width, .height]
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.spacing = 5
    stack.frame = NSRect(x: 10, y: 755, width: 1080, height: 32)
    stack.autoresizingMask = [.width, .minYMargin]
    for (title, action) in [
      ("Refresh status", #selector(refresh)), ("Request screen", #selector(requestScreen)),
      ("Request AX", #selector(requestAX)), ("Launch fixture", #selector(launchFixture)),
      ("Start capture", #selector(startCapture)), ("Stop", #selector(stopCapture)),
      ("Input OFF", #selector(toggleInput)), ("Mouse CG", #selector(toggleMouseMode)),
      ("0.5×", #selector(zoomHalf)), ("1×", #selector(zoomOne)), ("2×", #selector(zoomTwo)),
    ] {
      let button = NSButton(title: title, target: self, action: action)
      if title == "Input OFF" { inputButton = button }
      stack.addArrangedSubview(button)
    }
    root.addSubview(stack)
    status.frame = NSRect(x: 10, y: 630, width: 1080, height: 120)
    status.autoresizingMask = [.width, .minYMargin]
    root.addSubview(status)
    canvas.frame = NSRect(x: 10, y: 10, width: 1080, height: 610)
    canvas.autoresizingMask = [.width, .height]
    root.addSubview(canvas)
    canvas.input = { [weak self] type, point in self?.sendMouse(type, point) }
    canvas.keyboard = { [weak self] event, down in self?.sendKey(event, down) }
    window.contentView = root
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    refresh()
  }
  @objc func refresh() {
    if unknownStream != nil {
      status.stringValue = "Stream state unknown; retry Stop or Quit"
      return
    }
    status.stringValue =
      "Screen recording: \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted") | Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted") | Post events: \(CGPreflightPostEventAccess() ? "granted" : "not granted") | Input: \(inputEnabled ? "ON (fixture only)" : "OFF")\nLaunch fixture, then start capture. Right-drag pans; click canvas before typing. No access is requested automatically."
  }
  @objc func requestScreen() {
    _ = CGRequestScreenCaptureAccess()
    refresh()
  }
  @objc func requestAX() {
    _ = AXIsProcessTrustedWithOptions(
      [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    refresh()
  }
  @objc func launchFixture() {
    guard fixture?.isRunning != true else {
      status.stringValue = "Fixture already running"
      return
    }
    guard !session.busy, !stopping, unknownStream == nil else {
      status.stringValue = "Stop the previous capture before launching a fixture"
      return
    }
    fixtureReader?.readabilityHandler = nil
    fixtureReader = nil
    fixturePipeRead = nil
    fixture = nil
    handshake = nil
    fixtureGeneration += 1
    let generation = fixtureGeneration
    let executable = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(
      "InfiniteDesk Fixture.app/Contents/MacOS/Fixture")
    let process = Process()
    process.executableURL = executable
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
      try process.run()
      try pipe.fileHandleForWriting.close()
      fixture = process
      fixtureReader = pipe.fileHandleForReading
      fixturePipeRead = FixturePipeRead()
      handshake = FixtureHandshake(generation: generation, expectedPID: process.processIdentifier)
      status.stringValue = "Fixture PID \(process.processIdentifier): waiting for window identity"
      monitorFixturePipe(generation)
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
        guard let self, self.fixtureGeneration == generation, self.handshake?.windowID == nil else {
          return
        }
        self.failFixtureIdentity("Fixture identity timed out")
      }
    } catch {
      if process.isRunning { process.terminate() }
      status.stringValue = "Fixture launch failed: \(error)"
    }
  }
  func monitorFixturePipe(_ generation: Int) {
    guard let reader = fixtureReader, let pipeRead = fixturePipeRead else { return }
    reader.readabilityHandler = { [weak self] handle in
      // Disable readiness until the actor handles this bounded chunk, preserving order.
      handle.readabilityHandler = nil
      let result = pipeRead.read(handle)
      if case .ignored = result { return }
      Task { @MainActor [weak self] in
        guard let self, self.fixtureGeneration == generation else { return }
        guard case .data(let data) = result else {
          if case .end(let code) = result {
            self.failFixtureIdentity(
              "Fixture identity pipe closed or failed (errno \(code.map(String.init) ?? "none"))")
          }
          return
        }
        guard var handshake = self.handshake else {
          self.failFixtureIdentity("Fixture identity unavailable")
          return
        }
        let result = handshake.receive(data, generation: generation)
        self.handshake = handshake
        switch result {
        case .pending: break
        case .ready(let id):
          self.status.stringValue = "Fixture PID \(handshake.expectedPID), window \(id) ready"
        case .invalid:
          self.failFixtureIdentity("Fixture identity invalid, oversized, or duplicated")
          return
        case .stale: return
        }
        pipeRead.delivered()
        self.monitorFixturePipe(generation)
      }
    }
  }
  func failFixtureIdentity(_ reason: String) {
    fixtureGeneration += 1
    handshake = nil
    fixtureReader?.readabilityHandler = nil
    // Do not explicitly close a descriptor that a readiness callback may still hold.
    fixtureReader = nil
    fixturePipeRead = nil
    if session.busy || starting { stopCapture() }
    if fixture?.isRunning == true { fixture?.terminate() }
    status.stringValue = reason
  }
  func validFixture() -> Bool {
    guard let process = fixture, process.isRunning,
      let app = NSRunningApplication(processIdentifier: process.processIdentifier),
      app.bundleIdentifier == fixtureBundleID,
      app.executableURL?.standardizedFileURL == process.executableURL?.standardizedFileURL
    else { return false }
    return true
  }
  @objc func startCapture() {
    guard !stopping, unknownStream == nil, !session.busy, validFixture(), let process = fixture
    else {
      status.stringValue =
        "Start requires one running fixture and no active or unknown stream; retry Stop"
      return
    }
    guard let windowID = handshake?.windowID, handshake?.expectedPID == process.processIdentifier,
      handshake?.failed == false
    else {
      status.stringValue = "Fixture window identity not ready"
      return
    }
    let fixtureToken = fixtureGeneration
    guard CGPreflightScreenCaptureAccess() else {
      status.stringValue = "Screen Recording permission required"
      return
    }
    guard let generation = session.start() else { return }
    let pid = process.processIdentifier
    status.stringValue = "Finding fixture window…"
    starting = true
    Task { @MainActor in
      var candidateToStop: SCStream?
      var candidateOutput: LatestFrame?
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(
          false, onScreenWindowsOnly: false)
        guard session.isCurrent(generation) else {
          finishStartingCancellation()
          return
        }
        guard fixtureGeneration == fixtureToken, validFixture(), fixture?.processIdentifier == pid,
          handshake?.windowID == windowID
        else {
          session.cancel()
          starting = false
          status.stringValue = "Fixture process or window identity changed"
          return
        }
        let matches = matchingFixtureWindows(
          content.windows, pid: pid, expectedPID: pid, windowID: windowID,
          bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
          id: { $0.windowID }, owner: { $0.owningApplication?.processID })
        guard matches.count == 1, let selected = matches.first else {
          session.cancel()
          starting = false
          status.stringValue =
            "Fixture PID \(pid), window \(windowID): \(matches.isEmpty ? "not found in ScreenCaptureKit" : "duplicate ScreenCaptureKit IDs")"
          return
        }
        let config = SCStreamConfiguration()
        config.width = 1280
        config.height = 960
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.capturesAudio = false
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        let frameOutput = LatestFrame()
        let candidate = SCStream(
          filter: SCContentFilter(desktopIndependentWindow: selected), configuration: config,
          delegate: frameOutput)
        try candidate.addStreamOutput(frameOutput, type: .screen, sampleHandlerQueue: captureQueue)
        output = frameOutput
        stream = candidate
        candidateToStop = candidate
        candidateOutput = frameOutput
        targetWindow = selected
        try await candidate.startCapture()
        guard session.isCurrent(generation) else {
          await stopStream(candidate, frameOutput: frameOutput)
          stream = nil
          finishStartingCancellation()
          return
        }
        starting = false
        startTimer()
        status.stringValue = "Capturing fixture PID \(pid), window \(selected.windowID); input OFF"
      } catch {
        let startError = error
        if let candidateToStop { await stopStream(candidateToStop, frameOutput: candidateOutput) }
        stream = nil
        if session.isCurrent(generation) {
          session.cancel()
          starting = false
          output = nil
          targetWindow = nil
          if unknownStream == nil { status.stringValue = "Capture failed: \(startError)" }
        } else {
          finishStartingCancellation()
        }
      }
    }
  }
  func finishStartingCancellation() {
    starting = false
    stopping = false
    completeQuitIfPending()
  }
  func completeQuitIfPending() {
    guard terminatePending else { return }
    terminatePending = false
    terminateFixture()
    NSApp.reply(toApplicationShouldTerminate: true)
  }
  func stopStream(_ old: SCStream, frameOutput: LatestFrame?) async {
    do {
      try await old.stopCapture()
      await withCheckedContinuation { continuation in captureQueue.async { continuation.resume() } }
      unknownStream = nil
      unknownOutput = nil
      status.stringValue = "Capture stopped"
    } catch {
      unknownStream = old
      unknownOutput = frameOutput
      status.stringValue = "Stop failed; stream state unknown: \(error). Retry Stop or Quit."
    }
  }
  @objc func stopCapture() {
    timer?.invalidate()
    timer = nil
    releaseInput()
    session.cancel()
    inputEnabled = false
    geometryOK = false
    lastAXRect = nil
    lastStreamActivity = nil
    axDiagnostic = "not requested"
    let frameOutput = output
    output = nil
    targetWindow = nil
    canvas.image = nil
    canvas.sourceRect = .zero
    canvas.needsDisplay = true
    if starting {
      stopping = true
      return
    }
    guard !stopping else { return }
    guard let old = stream ?? unknownStream else {
      refresh()
      return
    }
    let retainedOutput = frameOutput ?? unknownOutput
    stream = nil
    stopping = true
    Task { @MainActor in
      await stopStream(old, frameOutput: retainedOutput)
      stopping = false
      completeQuitIfPending()
    }
  }
  func startTimer() {
    timer = Timer.scheduledTimer(
      timeInterval: 1.0 / 30.0, target: self, selector: #selector(showLatest), userInfo: nil,
      repeats: true)
  }
  @objc func showLatest() {
    guard let output else { return }
    guard let (frame, dropped, error, activity) = output.take() else { return }
    lastStreamActivity = activity
    if let error {
      invalidateFrame(error)
      return
    }
    guard validFixture() else {
      stopCapture()
      status.stringValue = "Fixture exited"
      return
    }
    if inputEnabled && axCheck.checkedAt != nil
      && !axCheck.fresh(now: ProcessInfo.processInfo.systemUptime)
    {
      releaseInput()
      inputEnabled = false
      geometryOK = false
      axDiagnostic = "AX check expired; input disabled"
      updateGeometryStatus()
    }
    if inputEnabled
      && !streamActivityFresh(last: lastStreamActivity, now: ProcessInfo.processInfo.systemUptime)
    {
      releaseInput()
      inputEnabled = false
      geometryOK = false
      axDiagnostic = "stream callback inactive for 2 seconds; input disabled"
      updateGeometryStatus()
    }
    requestAXGeometry()
    guard let frame, stream != nil, let target = targetWindow else { return }
    let full = CIImage(cvPixelBuffer: frame.buffer)
    let crop = CGRect(
      x: frame.content.minX * frame.scale, y: full.extent.height - frame.content.maxY * frame.scale,
      width: frame.content.width * frame.scale, height: frame.content.height * frame.scale)
    guard
      [
        crop.minX, crop.minY, crop.width, crop.height, frame.screen.minX, frame.screen.minY,
        frame.screen.width, frame.screen.height,
      ].allSatisfy(\.isFinite), crop.width > 0, crop.height > 0, full.extent.contains(crop),
      let image = context.createCGImage(full, from: crop)
    else {
      invalidateFrame("Invalid frame geometry")
      return
    }
    canvas.image = image
    canvas.sourceRect = frame.screen
    canvas.displaySize = CGSize(
      width: frame.content.width / frame.contentScale,
      height: frame.content.height / frame.contentScale)
    canvas.needsDisplay = true
    validateGeometry()
    frameDiagnostic =
      "Fixture \(target.windowID) | frame \(CVPixelBufferGetWidth(frame.buffer))×\(CVPixelBufferGetHeight(frame.buffer)) | scale \(frame.scale), content scale \(frame.contentScale) | replaced \(dropped)\nInitial SCK window frame: \(target.frame) | contentRect: \(frame.content)"
    updateGeometryStatus()
  }
  func invalidateFrame(_ reason: String) {
    releaseInput()
    inputEnabled = false
    geometryOK = false
    lastAXRect = nil
    canvas.image = nil
    canvas.sourceRect = .zero
    canvas.needsDisplay = true
    frameDiagnostic = "frame unavailable: \(reason)"
    axDiagnostic = "unavailable: \(reason)"
    updateGeometryStatus()
  }
  func updateGeometryStatus() {
    let screen = canvas.sourceRect
    let ax = lastAXRect.map { String(describing: $0) } ?? "unavailable"
    let down = lastMouseDown.map { String(describing: $0) } ?? "none"
    let up = lastMouseUp.map { String(describing: $0) } ?? "none"
    status.stringValue =
      "\(frameDiagnostic) | input \(inputEnabled ? "ON" : "OFF")\nSCK screenRect: \(screen) | AX rect: \(ax)\nAX: \(axDiagnostic)\nPosted mouse: \(postedMouseEvents), down=\(down), up=\(up) | \(mouseConstruction)"
  }
  func validateGeometry() {
    let r = canvas.sourceRect
    geometryOK =
      lastAXRect.map {
        abs($0.minX - r.minX) < 2 && abs($0.minY - r.minY) < 2 && abs($0.width - r.width) < 2
          && abs($0.height - r.height) < 2
      } ?? false
    if lastAXRect != nil {
      axDiagnostic =
        geometryOK
        ? "main candidates=1, AX windows=\(axWindowCount); geometry matched"
        : "main candidates=1, AX windows=\(axWindowCount); geometry mismatch; input disabled"
      if !geometryOK {
        releaseInput()
        inputEnabled = false
      }
    }
  }
  func requestAXGeometry() {
    guard inputEnabled, let process = fixture,
      let request = axCheck.begin(now: ProcessInfo.processInfo.systemUptime)
    else { return }
    let generation = session.generation
    let pid = process.processIdentifier
    axQueue.async { [weak self] in
      let result = fixtureAXRect(pid)
      Task { @MainActor [weak self] in
        guard let self, self.session.isCurrent(generation), self.inputEnabled else { return }
        switch self.axCheck.complete(request, now: ProcessInfo.processInfo.systemUptime) {
        case .stale: return
        case .expired:
          self.lastAXRect = nil
          self.axDiagnostic = "AX check expired; input disabled"
          self.releaseInput()
          self.inputEnabled = false
          self.geometryOK = false
          self.updateGeometryStatus()
          return
        case .accepted: break
        }
        switch result {
        case .failure(let reason):
          self.lastAXRect = nil
          self.axDiagnostic = reason
          self.releaseInput()
          self.inputEnabled = false
          self.geometryOK = false
        case .rect(let rect, let count):
          self.lastAXRect = rect
          self.axWindowCount = count
          self.validateGeometry()
        }
        self.updateGeometryStatus()
      }
    }
  }
  @objc func toggleInput(_ sender: NSButton) {
    if inputEnabled {
      releaseInput()
      inputEnabled = false
      sender.title = "Input OFF"
    } else if stream != nil && canvas.image != nil && canvas.sourceRect.width > 0 && validFixture()
      && AXIsProcessTrusted() && CGPreflightPostEventAccess()
    {
      geometryOK = false
      lastAXRect = nil
      axDiagnostic = "checking"
      inputEnabled = true
      sender.title = "Input ON"
      requestAXGeometry()
      updateGeometryStatus()
    } else {
      axDiagnostic = "input unavailable: capture, fixture, AX or event-post permission"
      updateGeometryStatus()
    }
  }
  @objc func zoomHalf() {
    canvas.zoom = 0.5
    canvas.needsDisplay = true
  }
  @objc func zoomOne() {
    canvas.zoom = 1
    canvas.needsDisplay = true
  }
  @objc func zoomTwo() {
    canvas.zoom = 2
    canvas.needsDisplay = true
  }
  func permitted() -> Bool {
    inputEnabled && geometryOK
      && streamActivityFresh(last: lastStreamActivity, now: ProcessInfo.processInfo.systemUptime)
      && axCheck.fresh(now: ProcessInfo.processInfo.systemUptime) && stream != nil && validFixture()
      && AXIsProcessTrusted() && CGPreflightPostEventAccess()
  }
  @objc func toggleMouseMode(_ sender: NSButton) {
    releaseInput()
    switch mouseMode {
    case .cg:
      mouseMode = .appKitGlobal
      sender.title = "Mouse AppKit global"
    case .appKitGlobal:
      mouseMode = .appKitNative
      sender.title = "Mouse AppKit native"
    case .appKitNative:
      mouseMode = .appKitLocalCG
      sender.title = "Mouse AppKit local CG"
    case .appKitLocalCG:
      mouseMode = .cg
      sender.title = "Mouse CG"
    }
    mouseConstruction = "\(sender.title) selected"
    updateGeometryStatus()
  }
  @discardableResult
  func postMouse(_ type: CGEventType, _ point: CGPoint) -> Bool {
    guard validFixture(), let process = fixture, let id = targetWindow?.windowID else {
      return false
    }
    if type == .leftMouseDown {
      mouseEventNumber = mouseEventNumber == Int.max ? 1 : mouseEventNumber + 1
    }
    let event: CGEvent
    var appKitConstruction: String?
    if mouseMode != .cg {
      let appKitType: NSEvent.EventType
      switch type {
      case .leftMouseDown: appKitType = .leftMouseDown
      case .leftMouseDragged: appKitType = .leftMouseDragged
      case .leftMouseUp: appKitType = .leftMouseUp
      default: return false
      }
      guard let local = windowBasePoint(global: point, frame: canvas.sourceRect) else {
        mouseConstruction = "AppKit window geometry invalid"
        updateGeometryStatus()
        return false
      }
      let eventPoint: CGPoint
      if mouseMode == .appKitLocalCG {
        guard let screen = NSScreen.screens.first,
          let point = experimentalLocalCGPoint(
            global: point, frame: canvas.sourceRect, primaryScreen: screen.frame)
        else {
          mouseConstruction = "Local CG experiment: screen geometry unavailable"
          updateGeometryStatus()
          return false
        }
        eventPoint = point
      } else {
        eventPoint = local
      }
      guard
        let appEvent = NSEvent.mouseEvent(
          with: appKitType, location: eventPoint, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(id), context: nil,
          eventNumber: mouseEventNumber, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1),
        let cgEvent = appEvent.cgEvent
      else {
        mouseConstruction = "AppKit event/CG conversion unavailable"
        updateGeometryStatus()
        return false
      }
      let originalWindow = appEvent.windowNumber
      event = cgEvent
      let constructorGlobal = event.location
      if mouseMode == .appKitGlobal { event.location = point }
      let modeName: String
      switch mouseMode {
      case .appKitGlobal: modeName = "AppKit global"
      case .appKitNative: modeName = "AppKit native"
      case .appKitLocalCG: modeName = "AppKit local CG experiment"
      case .cg: modeName = "CG"
      }
      appKitConstruction =
        "\(modeName) NS window=\(originalWindow) desired local=\(local) input=\(eventPoint), constructor CG=\(constructorGlobal)"
    } else {
      guard
        let cgEvent = CGEvent(
          mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
      else {
        mouseConstruction = "CG event unavailable"
        updateGeometryStatus()
        return false
      }
      event = cgEvent
      mouseConstruction = "CG event"
    }
    event.setIntegerValueField(.mouseEventNumber, value: Int64(mouseEventNumber))
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(id))
    event.setIntegerValueField(
      .mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(id))
    if let appKitConstruction {
      let roundTrip = NSEvent(cgEvent: event)
      let roundTripWindow = roundTrip.map { String($0.windowNumber) } ?? "nil"
      let roundTripLocal = roundTrip.map { String(describing: $0.locationInWindow) } ?? "nil"
      mouseConstruction =
        "\(appKitConstruction), sent CG=\(event.location), roundtrip window=\(roundTripWindow) local=\(roundTripLocal)"
    }
    event.postToPid(process.processIdentifier)
    postedMouseEvents &+= 1
    if type == .leftMouseDown { lastMouseDown = point }
    if type == .leftMouseUp { lastMouseUp = point }
    updateGeometryStatus()
    return true
  }
  func sendMouse(_ type: CGEventType, _ point: CGPoint?) {
    guard permitted() else {
      releaseInput()
      return
    }
    if type == .leftMouseUp {
      if let release = pressed.mouseUp(at: point) { postMouse(type, release) }
      return
    }
    guard let point else { return }
    if type == .leftMouseDown {
      if postMouse(type, point) { pressed.mouseDown(point) }
    } else if type == .leftMouseDragged, pressed.mouse != nil {
      if postMouse(type, point) { pressed.mouseMove(point) }
    }
  }
  func postKey(_ code: UInt16, _ down: Bool, _ flags: UInt64 = 0) {
    guard validFixture(), let process = fixture,
      let key = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
    else { return }
    key.flags = CGEventFlags(rawValue: flags)
    key.postToPid(process.processIdentifier)
  }
  func sendKey(_ event: NSEvent, _ down: Bool) {
    if !down {
      if pressed.keyUp(event.keyCode) { postKey(event.keyCode, false) }
      return
    }
    guard permitted() else {
      releaseInput()
      return
    }
    pressed.keyDown(event.keyCode)
    postKey(event.keyCode, true, UInt64(event.modifierFlags.rawValue))
  }
  func releaseInput() {
    if let point = pressed.mouseUp() { postMouse(.leftMouseUp, point) }
    for key in pressed.takeKeys() { postKey(key, false) }
  }
  func applicationDidResignActive(_ notification: Notification) {
    if inputEnabled { axDiagnostic = "probe lost app focus; input disabled" }
    releaseInput()
    inputEnabled = false
    if stream != nil { updateGeometryStatus() }
  }
  func terminateFixture() {
    fixtureGeneration += 1
    handshake = nil
    fixtureReader?.readabilityHandler = nil
    // Do not explicitly close a descriptor that a readiness callback may still hold.
    fixtureReader = nil
    fixturePipeRead = nil
    if fixture?.isRunning == true { fixture?.terminate() }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if unknownStream != nil && !stopping {
      session.cancel()
      releaseInput()
      terminateFixture()
      return .terminateNow
    }
    if stopping || stream != nil || starting {
      terminatePending = true
      if !stopping { stopCapture() }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        self?.completeQuitIfPending()
      }
      return .terminateLater
    }
    session.cancel()
    releaseInput()
    terminateFixture()
    return .terminateNow
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(
  withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
mainMenu.addItem(appMenuItem)
app.mainMenu = mainMenu
let delegate = ProbeDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
