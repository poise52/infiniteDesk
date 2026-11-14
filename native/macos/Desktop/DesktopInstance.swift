import Darwin
import Foundation

final class DesktopInstance {
  private let descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  static func acquire() throws -> DesktopInstance? {
    let directory = try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("dev.infinitedesk.desktop", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("manager.lock").path
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      close(descriptor)
      if code == EWOULDBLOCK { return nil }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    return DesktopInstance(descriptor: descriptor)
  }

  deinit {
    close(descriptor)
  }
}
