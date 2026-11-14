import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import QuartzCore
@preconcurrency import ScreenCaptureKit

// The serial output queue owns the context, pending buffers, and publication flag.
// At most one latest buffer per stream and one main-queue image are retained.
private final class FrameProcessor: NSObject, SCStreamOutput, @unchecked Sendable {
  private let context = CIContext()
  let queue = DispatchQueue(label: "dev.infinitedesk.capture.frames", qos: .userInitiated)
  private var pending: [ObjectIdentifier: (SCStream, CMSampleBuffer)] = [:]
  private var publishing = false
  let deliver: @MainActor @Sendable (SCStream, CGImage?, SCFrameStatus) -> Void

  init(deliver: @escaping @MainActor @Sendable (SCStream, CGImage?, SCFrameStatus) -> Void) {
    self.deliver = deliver
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard type == .screen, CMSampleBufferIsValid(sample),
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]],
      let raw = attachments.first?[.status] as? Int,
      let status = SCFrameStatus(rawValue: raw)
    else { return }
    if status == .blank || status == .stopped {
      pending.removeValue(forKey: ObjectIdentifier(stream))
      DispatchQueue.main.async { self.deliver(stream, nil, status) }
      return
    }
    guard status == .complete else { return }
    pending[ObjectIdentifier(stream)] = (stream, sample)
    publishNext()
  }

  private func publishNext() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !publishing, let key = pending.keys.first,
      let (stream, sample) = pending.removeValue(forKey: key)
    else { return }
    guard let pixels = CMSampleBufferGetImageBuffer(sample) else {
      publishNext()
      return
    }
    let image = CIImage(cvPixelBuffer: pixels)
    guard let rendered = context.createCGImage(image, from: image.extent) else {
      publishNext()
      return
    }
    publishing = true
    DispatchQueue.main.async {
      self.deliver(stream, rendered, .complete)
      self.queue.async {
        self.publishing = false
        self.publishNext()
      }
    }
  }
}

@MainActor
final class WindowCapture: NSObject, SCStreamDelegate {
  let layer = CALayer()
  private var processor: FrameProcessor!
  var onUpdate: ((String, Bool) -> Void)?
  #if CAPTURE_TESTING
    var testOnImage: ((CGImage) -> Void)?
    func beginFixture(_ filter: SCContentFilter) {
      picking = true
      begin(filter)
    }
  #endif
  private var stream: SCStream?
  private var selectedApp: NSRunningApplication?
  private var selectedWindow: WindowFocusIdentity?
  private var focusGate: WindowFocusGate?
  var textGate: WindowTextGate?
  private var focusTransition = false
  private var pendingStream: SCStream?
  private var pendingFrame: CGImage?
  private var generation = 0
  private var picking = false
  private var destroyed = false
  private var startTask: Task<Void, Never>?

  override init() {
    super.init()
    layer.contentsGravity = .resizeAspect
    layer.backgroundColor = NSColor.black.cgColor
    processor = FrameProcessor { [weak self] stream, image, status in
      self?.acceptFrame(stream, image: image, status: status)
    }
  }

  func selectWindow() {
    guard !destroyed, !picking else { return }
    cancelPendingFocus()
    guard WindowPickerCoordinator.shared.present(self) else {
      onUpdate?("Finish the other window selection first", false)
      return
    }
    picking = true
  }

  func ownsPickerStream(_ id: ObjectIdentifier) -> Bool {
    stream.map(ObjectIdentifier.init) == id || pendingStream.map(ObjectIdentifier.init) == id
  }

  private func endPicker() { picking = false }

  private func releasePickerIfIdle() {
    guard !picking, stream == nil, pendingStream == nil else { return }
    WindowPickerCoordinator.shared.release(self)
  }

  func pickerCancelled() {
    endPicker()
    releasePickerIfIdle()
  }

  func pickerFailed(_ message: String) {
    endPicker()
    releasePickerIfIdle()
    onUpdate?("Picker failed: \(message)", false)
  }

  func pickerUpdated(_ filter: SCContentFilter, streamID: ObjectIdentifier?) {
    if let stream, streamID == ObjectIdentifier(stream), !picking {
      updateExisting(stream, filter: filter)
    } else if streamID == nil {
      begin(filter)
    }
  }

  private func updateExisting(_ stream: SCStream, filter: SCContentFilter) {
    cancelPendingFocus()
    focusTransition = true
    generation += 1
    let token = generation
    startTask?.cancel()
    startTask = Task { @MainActor [weak self] in
      do {
        try await stream.updateContentFilter(filter)
        guard let self, !self.destroyed, self.generation == token, self.stream === stream else {
          return
        }
        self.focusTransition = false
        self.selectedApp = nil
        self.selectedWindow = nil
        var label = "Live window preview"
        if #available(macOS 15.2, *), filter.includedWindows.count == 1,
          let owner = filter.includedWindows.first?.owningApplication
        {
          self.selectedApp = NSRunningApplication(processIdentifier: owner.processID)
          if let window = filter.includedWindows.first, window.windowID != 0, owner.processID > 0 {
            self.selectedWindow = WindowFocusIdentity(
              windowID: window.windowID, pid: owner.processID)
          }
          label = "Preview · \(owner.applicationName)"
        }
        self.onUpdate?(label, true)
      } catch {
        guard let self, !self.destroyed, self.generation == token else { return }
        self.focusTransition = false
        self.onUpdate?("Capture update failed: \(error.localizedDescription)", false)
      }
    }
  }

  private func begin(_ filter: SCContentFilter) {
    guard picking, !destroyed else { return }
    endPicker()
    cancelPendingFocus()
    focusTransition = true
    generation += 1
    let token = generation
    startTask?.cancel()
    let config = SCStreamConfiguration()
    let rect = filter.contentRect
    let scale = Double(filter.pointPixelScale)
    let sourceWidth = max(1, rect.width * scale)
    let sourceHeight = max(1, rect.height * scale)
    let reduction = min(1, 1600 / sourceWidth, 1200 / sourceHeight)
    guard sourceWidth.isFinite, sourceHeight.isFinite, reduction.isFinite else {
      focusTransition = false
      releasePickerIfIdle()
      onUpdate?("Capture dimensions are invalid", false)
      return
    }
    let width = max(1, Int((sourceWidth * reduction).rounded()))
    let height = max(1, Int((sourceHeight * reduction).rounded()))
    config.width = width
    config.height = height
    config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
    config.queueDepth = 3
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = true
    config.capturesAudio = false
    let candidate = SCStream(filter: filter, configuration: config, delegate: self)
    do {
      try candidate.addStreamOutput(processor, type: .screen, sampleHandlerQueue: processor.queue)
    } catch {
      focusTransition = false
      releasePickerIfIdle()
      onUpdate?("Capture failed: \(error.localizedDescription)", false)
      return
    }
    pendingStream = candidate
    pendingFrame = nil
    var application: NSRunningApplication?
    var identity: WindowFocusIdentity?
    var label = "Live window preview"
    if #available(macOS 15.2, *), filter.includedWindows.count == 1,
      let owner = filter.includedWindows.first?.owningApplication
    {
      application = NSRunningApplication(processIdentifier: owner.processID)
      if let window = filter.includedWindows.first, window.windowID != 0, owner.processID > 0 {
        identity = WindowFocusIdentity(windowID: window.windowID, pid: owner.processID)
      }
      label = "Preview · \(owner.applicationName)"
    }
    startTask = Task { @MainActor [weak self] in
      do {
        try await candidate.startCapture()
        guard let self, !self.destroyed, self.generation == token, !Task.isCancelled else {
          try? await candidate.stopCapture()
          return
        }
        let previous = self.stream
        self.focusGate?.cancel()
        self.focusGate = nil
        self.stream = candidate
        self.focusTransition = false
        self.selectedApp = application
        self.selectedWindow = identity
        self.pendingStream = nil
        self.clearLayer()
        if let frame = self.pendingFrame { self.display(frame) }
        self.pendingFrame = nil
        self.onUpdate?(label, true)
        if let previous { try? await previous.stopCapture() }
      } catch {
        guard let self, !self.destroyed, self.generation == token else { return }
        self.pendingStream = nil
        self.pendingFrame = nil
        self.focusTransition = false
        self.releasePickerIfIdle()
        self.onUpdate?("Capture failed: \(error.localizedDescription)", false)
      }
    }
  }

  var canOpenApplication: Bool { selectedApp != nil }
  var canFocusWindow: Bool {
    !picking && !focusTransition && selectedWindow != nil && selectedApp != nil && stream != nil
  }

  var textTarget: (WindowFocusIdentity, NSRunningApplication)? {
    guard canFocusWindow, let selectedWindow, let selectedApp,
      selectedApp.bundleIdentifier == "com.google.Chrome"
    else { return nil }
    return (selectedWindow, selectedApp)
  }

  func cancelPendingFocus() {
    textGate?.cancel()
    textGate = nil
    focusGate?.cancel()
    focusGate = nil
  }

  func focusWindow(completion: @escaping @MainActor @Sendable (String) -> Void) {
    guard canFocusWindow, let identity = selectedWindow, let app = selectedApp else {
      completion("Selected window is no longer available.")
      return
    }
    focusGate?.cancel()
    let gate = WindowFocusGate()
    focusGate = gate
    requestWindowFocus(identity: identity, app: app, gate: gate, completion: completion)
  }

  private func clearLayer() {
    layer.contents = nil
  }

  private func display(_ image: CGImage) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.contents = image
    CATransaction.commit()
    #if CAPTURE_TESTING
      testOnImage?(image)
    #endif
  }

  func openApplication() {
    guard let app = selectedApp, !app.isTerminated else { return }
    app.activate()
  }

  func stop() {
    WindowPickerCoordinator.shared.release(self)
    generation += 1
    endPicker()
    startTask?.cancel()
    startTask = nil
    selectedApp = nil
    selectedWindow = nil
    focusTransition = false
    cancelPendingFocus()
    pendingStream = nil
    pendingFrame = nil
    clearLayer()
    if let previous = stream {
      stream = nil
      Task { try? await previous.stopCapture() }
    }
    releasePickerIfIdle()
  }

  func destroy() {
    destroyed = true
    stop()
    onUpdate = nil
  }

  private func acceptFrame(_ stream: SCStream, image: CGImage?, status: SCFrameStatus) {
    if status == .complete, let image {
      if pendingStream === stream {
        pendingFrame = image
      } else if self.stream === stream {
        display(image)
      }
    } else if status == .blank || status == .stopped {
      if pendingStream === stream { pendingFrame = nil }
      if self.stream === stream {
        cancelPendingFocus()
        selectedWindow = nil
        clearLayer()
        onUpdate?("Capture is blank or stopped; select the window again.", false)
      }
    }
  }

  nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
    let message = error.localizedDescription
    Task { @MainActor [weak self] in
      guard let self else { return }
      if self.pendingStream === stream {
        self.generation += 1
        self.startTask?.cancel()
        self.pendingStream = nil
        self.pendingFrame = nil
        self.focusTransition = false
        self.releasePickerIfIdle()
        self.onUpdate?("Capture stopped: \(message)", false)
        return
      }
      guard self.stream === stream else { return }
      self.stream = nil
      self.selectedApp = nil
      self.selectedWindow = nil
      self.focusTransition = false
      self.cancelPendingFocus()
      self.clearLayer()
      self.releasePickerIfIdle()
      self.onUpdate?("Capture stopped: \(message)", false)
    }
  }
}
