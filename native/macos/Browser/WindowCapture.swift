import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import QuartzCore
@preconcurrency import ScreenCaptureKit

struct CaptureFrameGeometry: Sendable {
  let imageSize: CGSize
  let contentPixels: CGRect
  let sourceSize: CGSize

  init?(
    imageSize: CGSize, contentRect: CGRect, screenRect: CGRect,
    scaleFactor: CGFloat, contentScale: CGFloat
  ) {
    let values = [
      imageSize.width, imageSize.height, contentRect.minX, contentRect.minY,
      contentRect.width, contentRect.height, screenRect.minX, screenRect.minY,
      screenRect.width, screenRect.height, scaleFactor, contentScale,
    ]
    guard values.allSatisfy(\.isFinite), imageSize.width > 0, imageSize.height > 0,
      contentRect.width > 0, contentRect.height > 0, screenRect.width > 0,
      screenRect.height > 0, scaleFactor > 0, contentScale > 0
    else { return nil }
    let pixels = CGRect(
      x: contentRect.minX * scaleFactor, y: contentRect.minY * scaleFactor,
      width: contentRect.width * scaleFactor, height: contentRect.height * scaleFactor)
    guard pixels.minX >= 0, pixels.minY >= 0,
      pixels.maxX <= imageSize.width + 1, pixels.maxY <= imageSize.height + 1,
      abs(contentRect.width / contentScale - screenRect.width) <= 1,
      abs(contentRect.height / contentScale - screenRect.height) <= 1
    else { return nil }
    self.imageSize = imageSize
    contentPixels = pixels
    sourceSize = screenRect.size
  }

  func normalizedPoint(_ point: CGPoint, in bounds: CGRect, flipped: Bool) -> CGPoint? {
    guard
      [point.x, point.y, bounds.minX, bounds.minY, bounds.width, bounds.height]
        .allSatisfy(\.isFinite), bounds.width > 0, bounds.height > 0,
      point.x >= bounds.minX, point.x <= bounds.maxX,
      point.y >= bounds.minY, point.y <= bounds.maxY
    else { return nil }
    let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    let origin = CGPoint(
      x: bounds.minX + (bounds.width - imageSize.width * fit) / 2,
      y: bounds.minY + (bounds.height - imageSize.height * fit) / 2)
    let topY = flipped ? point.y - origin.y : bounds.maxY - point.y - (origin.y - bounds.minY)
    let pixel = CGPoint(x: (point.x - origin.x) / fit, y: topY / fit)
    guard pixel.x >= contentPixels.minX, pixel.x < contentPixels.maxX,
      pixel.y >= contentPixels.minY, pixel.y < contentPixels.maxY
    else { return nil }
    return CGPoint(
      x: (pixel.x - contentPixels.minX) / contentPixels.width,
      y: (pixel.y - contentPixels.minY) / contentPixels.height)
  }
}

private struct CapturedFrame: @unchecked Sendable {
  // CGImage is immutable; image and geometry travel together from the output queue.
  let image: CGImage
  let geometry: CaptureFrameGeometry?
}

// The serial output queue owns the context, pending buffers, and publication flag.
// At most one latest buffer per stream and one main-queue image are retained.
private final class FrameProcessor: NSObject, SCStreamOutput, @unchecked Sendable {
  private let context = CIContext()
  let queue = DispatchQueue(label: "dev.infinitedesk.capture.frames", qos: .userInitiated)
  private var pending: [ObjectIdentifier: (SCStream, CMSampleBuffer)] = [:]
  private var publishing = false
  let deliver: @MainActor @Sendable (SCStream, CapturedFrame?, SCFrameStatus) -> Void

  init(deliver: @escaping @MainActor @Sendable (SCStream, CapturedFrame?, SCFrameStatus) -> Void) {
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
    if status == .blank || status == .stopped || status == .suspended {
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
    let attachments =
      (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
      as? [[SCStreamFrameInfo: Any]])?.first
    func rect(_ key: SCStreamFrameInfo) -> CGRect? {
      guard let value = attachments?[key] as? [String: Any] else { return nil }
      return CGRect(dictionaryRepresentation: value as CFDictionary)
    }
    var geometry: CaptureFrameGeometry?
    if let content = rect(.contentRect), let screen = rect(.screenRect),
      let scale = attachments?[.scaleFactor] as? CGFloat,
      let contentScale = attachments?[.contentScale] as? CGFloat
    {
      geometry = CaptureFrameGeometry(
        imageSize: CGSize(width: rendered.width, height: rendered.height),
        contentRect: content, screenRect: screen, scaleFactor: scale, contentScale: contentScale)
    }
    let frame = CapturedFrame(image: rendered, geometry: geometry)
    publishing = true
    DispatchQueue.main.async {
      self.deliver(stream, frame, .complete)
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
  var onInvalidate: (() -> Void)?
  #if CAPTURE_TESTING
    var testOnImage: ((CGImage) -> Void)?
    private var fixtureContentSize: CGSize?
    private var fixturePixelScale: CGFloat?
    func beginFixture(_ filter: SCContentFilter, sourceSize: CGSize, pixelScale: CGFloat) {
      fixtureContentSize = sourceSize
      fixturePixelScale = pixelScale
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
  private var pendingFrame: CapturedFrame?
  private(set) var displayedGeometry: CaptureFrameGeometry?
  private var generation = 0
  private var picking = false
  private var frameAvailable = false
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
    guard !destroyed, !picking, !focusTransition else { return }
    cancelPendingFocus()
    guard WindowPickerCoordinator.shared.present(self, replacing: stream) else {
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
    if let stream, streamID == ObjectIdentifier(stream) {
      endPicker()
      picking = true
      begin(filter)
    } else if streamID == nil {
      begin(filter)
    }
  }

  private func begin(_ filter: SCContentFilter) {
    guard picking, !destroyed else { return }
    endPicker()
    cancelPendingFocus()
    clearLayer()
    focusTransition = true
    generation += 1
    let token = generation
    startTask?.cancel()
    let config = SCStreamConfiguration()
    var rect = filter.contentRect
    var scale = Double(filter.pointPixelScale)
    #if CAPTURE_TESTING
      if let size = fixtureContentSize { rect.size = size }
      if let fixturePixelScale { scale = fixturePixelScale }
      fixtureContentSize = nil
      fixturePixelScale = nil
    #endif
    guard [rect.minX, rect.minY, rect.width, rect.height, scale].allSatisfy(\.isFinite),
      rect.width > 0, rect.height > 0, scale > 0
    else {
      focusTransition = false
      releasePickerIfIdle()
      onUpdate?("Capture dimensions are invalid", false)
      return
    }
    let sourceWidth = rect.width * scale
    let sourceHeight = rect.height * scale
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
    config.ignoreShadowsSingleWindow = true
    config.ignoreGlobalClipSingleWindow = true
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
    !picking && !focusTransition && frameAvailable
      && selectedWindow != nil && selectedApp != nil && stream != nil
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
    displayedGeometry = nil
    frameAvailable = false
    onInvalidate?()
  }

  private func display(_ frame: CapturedFrame) {
    let image = frame.image
    displayedGeometry = frame.geometry
    frameAvailable = true
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
    onInvalidate = nil
  }

  private func acceptFrame(_ stream: SCStream, image: CapturedFrame?, status: SCFrameStatus) {
    if status == .complete, let image {
      if pendingStream === stream {
        pendingFrame = image
      } else if self.stream === stream, !focusTransition {
        let resuming = !frameAvailable
        display(image)
        if resuming { onUpdate?("Live window preview", true) }
      }
    } else if status == .blank || status == .stopped || status == .suspended {
      if pendingStream === stream { pendingFrame = nil }
      if self.stream === stream, !focusTransition {
        cancelPendingFocus()
        if status != .suspended { selectedWindow = nil }
        clearLayer()
        onUpdate?(
          status == .suspended
            ? "Capture is suspended; waiting for a new frame."
            : "Capture is blank or stopped; select the window again.", false)
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
