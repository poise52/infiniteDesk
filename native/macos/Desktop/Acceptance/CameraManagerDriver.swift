import AppKit
import Darwin
import Foundation
import Security

private struct TestManagerProcess: Equatable {
  let seconds: UInt64
  let microseconds: UInt64

  static func read(_ pid: pid_t) throws -> Self {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
      info.pbi_uid == getuid(), info.pbi_ruid == getuid()
    else { throw Failure.message("Cannot verify the current user's test manager process") }
    return Self(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
  }
}

private func testManagerEnvironment(_ pid: pid_t) throws -> [String: String] {
  var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
  var length = 0
  guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0,
    length > MemoryLayout<Int32>.size, length <= 4 * 1024 * 1024
  else { throw Failure.message("Cannot verify the test manager's opt-in environment") }
  var bytes = [UInt8](repeating: 0, count: length)
  guard sysctl(&mib, u_int(mib.count), &bytes, &length, nil, 0) == 0 else {
    throw Failure.message("Cannot read the test manager's opt-in environment")
  }
  bytes.removeSubrange(length..<bytes.count)
  let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
  guard argc > 0, argc < 65536 else { throw Failure.message("Invalid test manager process arguments") }
  var offset = MemoryLayout<Int32>.size
  func advanceString() throws -> ArraySlice<UInt8> {
    guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else {
      throw Failure.message("Truncated test manager process arguments")
    }
    let result = bytes[offset..<end]
    offset = end + 1
    return result
  }
  _ = try advanceString()
  while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
  for _ in 0..<argc { _ = try advanceString() }
  let allowed: Set<String> = [
    "INFINITEDESK_TEST_STATE_PATH", "INFINITEDESK_TEST_CAMERA_JOURNAL_PATH", "INFINITEDESK_TEST_SESSION",
  ]
  var environment: [String: String] = [:]
  while offset < bytes.count, bytes[offset] != 0 {
    let field = try advanceString()
    guard let separator = field.firstIndex(of: 61) else { continue }
    let key = String(decoding: field[..<separator], as: UTF8.self)
    guard allowed.contains(key) else { continue }
    guard environment[key] == nil else { throw Failure.message("Duplicate test manager opt-in environment") }
    environment[key] = String(decoding: field[field.index(after: separator)...], as: UTF8.self)
  }
  return environment
}

private func testManagerSignature(_ pid: pid_t) throws {
  var guest: SecCode?
  guard SecCodeCopyGuestWithAttributes(
    nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary,
    SecCSFlags(rawValue: 0), &guest) == errSecSuccess, let guest
  else { throw Failure.message("Cannot verify the running test manager's signature") }
  var requirement: SecRequirement?
  guard SecRequirementCreateWithString(
    "identifier \"dev.infinitedesk.demo\"" as CFString, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
    SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
  else { throw Failure.message("The running process is not the signed InfiniteDesk manager") }
}

private func testManagerPath(_ path: String) throws -> URL {
  guard path.hasPrefix("/"), !path.utf8.contains(0) else {
    throw Failure.message("Test manager state and journal paths must be absolute")
  }
  let name = (path as NSString).lastPathComponent
  let parent = (path as NSString).deletingLastPathComponent
  guard !name.isEmpty, name != ".", name != "..", let canonical = realpath(parent, nil) else {
    throw Failure.message("Test manager paths need an existing canonical parent directory")
  }
  defer { free(canonical) }
  let canonicalParent = String(cString: canonical)
  let expected = (canonicalParent == "/" ? "/" : canonicalParent + "/") + name
  guard expected == path else {
    throw Failure.message("Test manager paths must use their canonical POSIX parent")
  }
  var info = stat()
  if lstat(path, &info) == 0 {
    guard info.st_mode & S_IFMT == S_IFREG else {
      throw Failure.message("Test manager state and journal must be regular files, not symlinks")
    }
  } else if errno != ENOENT {
    throw Failure.message("Cannot inspect the test manager path")
  }
  return URL(fileURLWithPath: path)
}

private func testManagerSnapshot(_ path: String) throws -> [String: Any] {
  let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
  guard descriptor >= 0 else { throw Failure.message("Cannot open the test manager snapshot safely") }
  defer { close(descriptor) }
  var info = stat()
  guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
    info.st_uid == getuid(), info.st_size > 0, info.st_size <= 1024 * 1024
  else { throw Failure.message("Invalid test manager snapshot") }
  var data = Data(count: Int(info.st_size))
  try data.withUnsafeMutableBytes { bytes in
    var offset = 0
    while offset < bytes.count {
      let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { throw Failure.message("Incomplete test manager snapshot") }
      offset += count
    }
  }
  guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw Failure.message("Invalid test manager snapshot document")
  }
  return snapshot
}

func testManager(
  command: String, pid: pid_t, session: String, statePath: String, journalPath: String
) throws -> [String: Any] {
  guard ["manager-identity", "manager-quit", "manager-kill"].contains(command), pid > 1,
    pid != getpid(), UUID(uuidString: session) != nil,
    Bundle.main.bundleIdentifier == "org.infinitedesk.tests.desktop-acceptance"
  else { throw Failure.message("Invalid guarded test manager command or session") }
  let stateURL = try testManagerPath(statePath)
  let journalURL = try testManagerPath(journalPath)
  guard stateURL != journalURL else { throw Failure.message("Test state and recovery journal must be separate files") }
  let initial = try TestManagerProcess.read(pid)
  let acceptanceDirectory = Bundle.main.bundleURL.deletingLastPathComponent()
  let targetDirectory = acceptanceDirectory.deletingLastPathComponent()
  let builds = targetDirectory.appendingPathComponent("InfiniteDesk-builds", isDirectory: true)
  let bundle = targetDirectory.appendingPathComponent("InfiniteDesk.app", isDirectory: true).resolvingSymlinksInPath()
  let relative = bundle.path.removingPrefix(builds.path + "/")
  let components = relative.split(separator: "/")
  guard acceptanceDirectory.lastPathComponent == "desktop-acceptance",
    targetDirectory.lastPathComponent == "target", components.count == 2,
    components[0].hasPrefix("build."), components[1] == "InfiniteDesk.app"
  else { throw Failure.message("Test manager must be the repository's current built product") }
  let executable = bundle.appendingPathComponent("Contents/MacOS/InfiniteDesk")
  guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
    app.bundleIdentifier == "dev.infinitedesk.demo",
    app.bundleURL?.resolvingSymlinksInPath() == bundle,
    app.executableURL?.resolvingSymlinksInPath() == executable
  else { throw Failure.message("PID is not the current InfiniteDesk product bundle") }
  var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
  guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
    path.withUnsafeBufferPointer({ String(validatingCString: $0.baseAddress!) }) == executable.path
  else { throw Failure.message("Test manager executable does not match its bundle") }
  try testManagerSignature(pid)
  let environment = try testManagerEnvironment(pid)
  guard environment["INFINITEDESK_TEST_SESSION"] == session,
    environment["INFINITEDESK_TEST_STATE_PATH"] == statePath,
    environment["INFINITEDESK_TEST_CAMERA_JOURNAL_PATH"] == journalPath
  else { throw Failure.message("PID lacks this acceptance session's exact opt-in environment") }
  let state = try testManagerSnapshot(statePath)
  guard (state["managerPID"] as? NSNumber)?.int32Value == pid,
    state["testSession"] as? String == session
  else { throw Failure.message("Snapshot does not belong to this test manager session") }
  guard try TestManagerProcess.read(pid) == initial, !app.isTerminated else {
    throw Failure.message("Test manager process changed during verification")
  }
  switch command {
  case "manager-kill":
    guard kill(pid, SIGKILL) == 0 else { throw Failure.message("Could not interrupt the verified test manager") }
  case "manager-quit":
    guard app.terminate() else { throw Failure.message("The verified test manager rejected its quit request") }
  default: break
  }
  return [
    "pid": pid, "bundlePath": bundle.path, "executablePath": executable.path,
    "processIdentity": ["seconds": initial.seconds, "microseconds": initial.microseconds],
    "testSession": session, "statePath": statePath, "journalPath": journalURL.path, "accepted": true,
  ]
}

private extension String {
  func removingPrefix(_ prefix: String) -> String {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
  }
}
