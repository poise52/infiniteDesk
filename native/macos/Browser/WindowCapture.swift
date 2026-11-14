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
final class WindowCapture: NSObject, SCContentSharingPickerObserver, SCStreamDelegate {
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
  private var pendingStream: SCStream?
  private var pendingFrame: CGImage?
  private var generation = 0
  private var picking = false
  private var registered = false
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
    picking = true
    let picker = SCContentSharingPicker.shared
    var configuration = SCContentSharingPickerConfiguration()
    configuration.allowedPickerModes = .singleWindow
    if let bundle = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [bundle] }
    picker.defaultConfiguration = configuration
    if !registered {
      picker.add(self)
      picker.isActive = true
      registered = true
    }
    picker.present(using: .window)
  }

  private func endPicker() {
    picking = false
  }

  private func releasePickerIfIdle() {
    guard registered, !picking, stream == nil, pendingStream == nil else { return }
    SCContentSharingPicker.shared.remove(self)
    SCContentSharingPicker.shared.isActive = false
    registered = false
  }

  nonisolated func contentSharingPicker(
    _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
  ) {
    Task { @MainActor [weak self] in
      self?.endPicker()
      self?.releasePickerIfIdle()
    }
  }

  nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
    let message = error.localizedDescription
    Task { @MainActor [weak self] in
      self?.endPicker()
      self?.releasePickerIfIdle()
      self?.onUpdate?("Picker failed: \(message)", false)
    }
  }

  nonisolated func contentSharingPicker(
    _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?
  ) {
    let streamID = stream.map(ObjectIdentifier.init)
    Task { @MainActor [weak self] in
      guard let self else { return }
      if let current = self.stream, streamID == ObjectIdentifier(current), !self.picking {
        self.updateExisting(current, filter: filter)
      } else {
        self.begin(filter)
      }
    }
  }

  private func updateExisting(_ stream: SCStream, filter: SCContentFilter) {
    generation += 1
    let token = generation
    startTask?.cancel()
    startTask = Task { @MainActor [weak self] in
      do {
        try await stream.updateContentFilter(filter)
        guard let self, !self.destroyed, self.generation == token, self.stream === stream else {
          return
        }
        self.selectedApp = nil
        var label = "Live window preview"
        if #available(macOS 15.2, *), filter.includedWindows.count == 1,
          let owner = filter.includedWindows.first?.owningApplication
        {
          self.selectedApp = NSRunningApplication(processIdentifier: owner.processID)
          label = "Preview · \(owner.applicationName)"
        }
        self.onUpdate?(label, true)
      } catch {
        guard let self, !self.destroyed, self.generation == token else { return }
        self.onUpdate?("Capture update failed: \(error.localizedDescription)", false)
      }
    }
  }

  private func begin(_ filter: SCContentFilter) {
    guard picking, !destroyed else { return }
    endPicker()
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
      releasePickerIfIdle()
      onUpdate?("Capture failed: \(error.localizedDescription)", false)
      return
    }
    pendingStream = candidate
    pendingFrame = nil
    var application: NSRunningApplication?
    var label = "Live window preview"
    if #available(macOS 15.2, *), filter.includedWindows.count == 1,
      let owner = filter.includedWindows.first?.owningApplication
    {
      application = NSRunningApplication(processIdentifier: owner.processID)
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
        self.stream = candidate
        self.selectedApp = application
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
        self.releasePickerIfIdle()
        self.onUpdate?("Capture failed: \(error.localizedDescription)", false)
      }
    }
  }

  var canOpenApplication: Bool { selectedApp != nil }

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
    generation += 1
    endPicker()
    startTask?.cancel()
    startTask = nil
    selectedApp = nil
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
      if self.stream === stream { clearLayer() }
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
        self.releasePickerIfIdle()
        self.onUpdate?("Capture stopped: \(message)", false)
        return
      }
      guard self.stream === stream else { return }
      self.stream = nil
      self.selectedApp = nil
      self.clearLayer()
      self.releasePickerIfIdle()
      self.onUpdate?("Capture stopped: \(message)", false)
    }
  }
}
