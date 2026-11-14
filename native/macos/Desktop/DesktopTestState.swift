import Foundation
import OSLog

// The lock owns the pending snapshot and drain state; only the serial queue performs I/O.
final class DesktopTestState: @unchecked Sendable {
  private struct Frame: Encodable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ frame: CGRect) {
      x = frame.origin.x
      y = frame.origin.y
      width = frame.size.width
      height = frame.size.height
    }
  }

  private struct Window: Encodable, Sendable {
    let id: UUID
    let pid: Int32
    let title: String
    let availability: String
    let originalFrame: Frame
    let worldFrame: Frame

    init(_ window: DesktopWindow) {
      id = window.id
      pid = window.pid
      title = window.title
      switch window.availability {
      case .available: availability = "available"
      case .unavailable: availability = "unavailable"
      case .closed: availability = "closed"
      }
      originalFrame = Frame(window.originalFrame)
      worldFrame = Frame(window.worldFrame)
    }
  }

  private struct Output: Encodable {
    let windows: [Window]
    let focusedID: UUID?
  }

  private struct Snapshot: Sendable {
    let windows: [DesktopWindow]
    let focusedID: UUID?
  }

  private static let logger = Logger(subsystem: "dev.infinitedesk.desktop", category: "test-state")
  private let fileURL: URL
  private let queue = DispatchQueue(label: "dev.infinitedesk.desktop-test-state", qos: .utility)
  private let lock = NSLock()
  private var pending: Snapshot?
  private var draining = false
  private var stopped = false

  private init(fileURL: URL) { self.fileURL = fileURL }

  static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) -> DesktopTestState? {
    guard let path = environment["INFINITEDESK_TEST_STATE_PATH"], !path.isEmpty else { return nil }
    guard path.hasPrefix("/") else {
      logger.error("Test snapshot export disabled: INFINITEDESK_TEST_STATE_PATH must be absolute.")
      return nil
    }
    return DesktopTestState(fileURL: URL(fileURLWithPath: path).standardizedFileURL)
  }

  func publish(windows: [DesktopWindow], focusedID: UUID?) {
    let snapshot = Snapshot(windows: windows, focusedID: focusedID)
    lock.lock()
    guard !stopped else { lock.unlock(); return }
    pending = snapshot
    let needsDrain = !draining
    draining = true
    lock.unlock()
    if needsDrain { queue.async { [self] in drain() } }
  }

  func stop() {
    lock.lock()
    stopped = true
    pending = nil
    lock.unlock()
  }

  private func drain() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    while true {
      lock.lock()
      guard let snapshot = pending else {
        draining = false
        lock.unlock()
        return
      }
      pending = nil
      lock.unlock()
      do {
        try FileManager.default.createDirectory(
          at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let output = Output(windows: snapshot.windows.map(Window.init), focusedID: snapshot.focusedID)
        try encoder.encode(output).write(to: fileURL, options: .atomic)
      } catch {
        let failure = error as NSError
        Self.logger.error("Test snapshot write failed domain=\(failure.domain, privacy: .public) code=\(failure.code)")
      }
    }
  }
}
