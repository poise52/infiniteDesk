import Darwin
import Foundation

struct DesktopCameraJournalEntry: Codable, Equatable, Sendable, Identifiable {
  let id: UUID
  let pid: pid_t
  let processIdentity: DesktopProcessIdentity
  let title: String
  let appName: String
  let bundleIdentifier: String?
  let originalFrame: CGRect
  let originalMinimized: Bool
  let bootSessionID: String?
  var lastIntendedFrame: CGRect
  var lastIntendedMinimized: Bool

  init(
    id: UUID, pid: pid_t, processIdentity: DesktopProcessIdentity, title: String,
    appName: String, bundleIdentifier: String?, originalFrame: CGRect,
    originalMinimized: Bool = false, bootSessionID: String? = desktopBootSessionID()
  ) {
    self.id = id
    self.pid = pid
    self.processIdentity = processIdentity
    self.title = title
    self.appName = appName
    self.bundleIdentifier = bundleIdentifier
    self.originalFrame = originalFrame
    self.originalMinimized = originalMinimized
    self.bootSessionID = bootSessionID
    lastIntendedFrame = originalFrame
    lastIntendedMinimized = originalMinimized
  }
}

func desktopBootSessionID() -> String? {
  var length = 0
  guard sysctlbyname("kern.bootsessionuuid", nil, &length, nil, 0) == 0,
    length > 1, length < 1024
  else { return nil }
  var bytes = [CChar](repeating: 0, count: length)
  guard sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0 else { return nil }
  return bytes.withUnsafeBufferPointer { buffer in
    guard let base = buffer.baseAddress else { return nil }
    return String(validatingCString: base)
  }
}

enum DesktopCameraJournalError: LocalizedError {
  case invalid(String)
  case locked
  case failed

  var errorDescription: String? {
    switch self {
    case .invalid(let reason): return "Recovery journal rejected: \(reason). Camera movement is blocked."
    case .locked: return "Another manager owns the recovery journal."
    case .failed: return "Recovery journal storage failed. Restart after checking the saved recovery file."
    }
  }
}

// The backend's serial AX queue owns this store. No I/O is performed by rendering or main-actor code.
final class DesktopCameraJournal {
  private struct Document: Codable {
    var version = 1
    let entries: [DesktopCameraJournalEntry]
  }

  let fileURL: URL
  private let lockDescriptor: Int32
  private var failed = false
  private(set) var entries: [DesktopCameraJournalEntry]
  private static let maximumBytes = 16 * 1024 * 1024

  init(fileURL: URL? = nil) throws {
    let resolved: URL
    if let fileURL {
      resolved = fileURL
    } else if let testState = ProcessInfo.processInfo.environment["INFINITEDESK_TEST_STATE_PATH"],
      !testState.isEmpty,
      let testJournal = ProcessInfo.processInfo.environment["INFINITEDESK_TEST_CAMERA_JOURNAL_PATH"]
    {
      guard testJournal.hasPrefix("/") else {
        throw DesktopCameraJournalError.invalid("test journal path must be absolute")
      }
      resolved = URL(fileURLWithPath: testJournal)
    } else {
      resolved = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      ).appendingPathComponent("dev.infinitedesk.desktop", isDirectory: true)
        .appendingPathComponent("camera-recovery.json")
    }
    self.fileURL = resolved
    let directory = resolved.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var directoryInfo = stat()
    guard lstat(directory.path, &directoryInfo) == 0,
      directoryInfo.st_mode & S_IFMT == S_IFDIR,
      directoryInfo.st_uid == getuid()
    else { throw DesktopCameraJournalError.invalid("unsafe recovery directory") }
    let descriptor = open(
      resolved.appendingPathExtension("lock").path,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw Self.posixError() }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      close(descriptor)
      if code == EWOULDBLOCK { throw DesktopCameraJournalError.locked }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    do {
      entries = try Self.load(resolved)
      lockDescriptor = descriptor
    } catch {
      close(descriptor)
      throw error
    }
  }

  deinit { close(lockDescriptor) }

  func prepare(_ entry: DesktopCameraJournalEntry) throws {
    guard !failed else { throw DesktopCameraJournalError.failed }
    try Self.validate(entry)
    if let existing = entries.first(where: { $0.id == entry.id }) {
      guard existing.originalFrame == entry.originalFrame,
        existing.originalMinimized == entry.originalMinimized,
        existing.pid == entry.pid, existing.processIdentity == entry.processIdentity,
        existing.bootSessionID == entry.bootSessionID
      else { throw DesktopCameraJournalError.invalid("an existing original cannot be replaced") }
      return
    }
    guard entries.count < 4096 else { throw DesktopCameraJournalError.invalid("too many entries") }
    try commit(entries + [entry])
  }

  func recordIntent(id: UUID, frame: CGRect, minimized: Bool) throws {
    guard let index = entries.firstIndex(where: { $0.id == id }) else {
      throw DesktopCameraJournalError.invalid("mutation has no saved original")
    }
    var candidate = entries
    candidate[index].lastIntendedFrame = frame
    candidate[index].lastIntendedMinimized = minimized
    try Self.validate(candidate[index])
    try commit(candidate)
  }

  // The caller must first confirm geometry and minimization on its exact live AX handle,
  // or obtain an explicit acknowledgement that the user recovered this entry manually.
  func complete(id: UUID) throws {
    guard entries.contains(where: { $0.id == id }) else { return }
    try commit(entries.filter { $0.id != id })
  }

  private static func validate(_ entry: DesktopCameraJournalEntry) throws {
    let frames = [entry.originalFrame, entry.lastIntendedFrame]
    guard entry.pid > 0, entry.processIdentity.microseconds < 1_000_000,
      let boot = entry.bootSessionID, UUID(uuidString: boot) != nil,
      frames.allSatisfy({ frame in
        [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite)
          && frame.size.width > 0 && frame.size.height > 0
      }), [entry.title, entry.appName, entry.bundleIdentifier ?? ""].allSatisfy({ $0.utf8.count <= 65536 })
    else { throw DesktopCameraJournalError.invalid("invalid process, boot identity, or geometry") }
  }

  private static func load(_ url: URL) throws -> [DesktopCameraJournalEntry] {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if descriptor < 0 {
      if errno == ENOENT { return [] }
      throw posixError()
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw posixError() }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_size > 0, info.st_size <= maximumBytes
    else { throw DesktopCameraJournalError.invalid("unsafe or oversized recovery file") }
    var data = Data(count: Int(info.st_size))
    try data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw posixError() }
        offset += count
      }
    }
    let document = try JSONDecoder().decode(Document.self, from: data)
    guard document.version == 1, document.entries.count <= 4096,
      Set(document.entries.map(\.id)).count == document.entries.count
    else { throw DesktopCameraJournalError.invalid("unknown schema or duplicate window IDs") }
    for entry in document.entries { try validate(entry) }
    return document.entries
  }

  private func commit(_ candidate: [DesktopCameraJournalEntry]) throws {
    guard !failed else { throw DesktopCameraJournalError.failed }
    let data = try JSONEncoder().encode(Document(entries: candidate))
    guard data.count <= Self.maximumBytes else { throw DesktopCameraJournalError.invalid("journal too large") }
    do {
      try durableReplace(data)
      entries = candidate
    } catch {
      // A rename may already have succeeded. Further writes could otherwise overwrite an
      // entry that reached disk but whose directory sync failed.
      failed = true
      throw error
    }
  }

  private func durableReplace(_ data: Data) throws {
    let directory = fileURL.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(".camera-recovery-\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw Self.posixError() }
    defer {
      close(descriptor)
      unlink(temporary.path)
    }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw Self.posixError() }
        offset += count
      }
    }
    guard fsync(descriptor) == 0 else { throw Self.posixError() }
    guard rename(temporary.path, fileURL.path) == 0 else { throw Self.posixError() }
    let directoryDescriptor = open(directory.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
    guard directoryDescriptor >= 0 else { throw Self.posixError() }
    defer { close(directoryDescriptor) }
    guard fsync(directoryDescriptor) == 0 else { throw Self.posixError() }
  }

  private static func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
