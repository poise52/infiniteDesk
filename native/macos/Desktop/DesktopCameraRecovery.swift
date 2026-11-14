import Foundation

enum DesktopCameraRecoveryProcess: String, Sendable {
  case sameInstance, exited, replaced, previousBoot, unknownBoot
}

struct DesktopCameraRecoveryItem: Sendable, Identifiable {
  let entry: DesktopCameraJournalEntry
  let process: DesktopCameraRecoveryProcess
  var id: UUID { entry.id }

  var explanation: String {
    switch process {
    case .sameInstance:
      return "The application is still running. Unminimize and restore the intended window manually; saved title and bounds cannot identify it safely after a crash."
    case .exited:
      return "The original application process exited. A reopened window is a different window; restore your layout manually before acknowledging this entry."
    case .replaced:
      return "The PID now belongs to a different process instance. The saved window will not be moved."
    case .previousBoot:
      return "This entry is from a previous system boot. The saved window will not be moved."
    case .unknownBoot:
      return "The current boot identity is unavailable. The saved window will not be moved."
    }
  }

  var instructions: String {
    let original = entry.originalFrame
    let intended = entry.lastIntendedFrame
    return "\(entry.appName) — \(entry.title)\nPID \(entry.pid), process start \(entry.processIdentity.seconds).\(entry.processIdentity.microseconds), bundle \(entry.bundleIdentifier ?? "unknown")\n"
      + "Original: x=\(original.origin.x), y=\(original.origin.y), width=\(original.width), height=\(original.height), minimized=\(entry.originalMinimized).\n"
      + "Last intended: x=\(intended.origin.x), y=\(intended.origin.y), width=\(intended.width), height=\(intended.height), minimized=\(entry.lastIntendedMinimized).\n"
      + explanation
  }
}

enum DesktopCameraRecovery {
  // There is no persisted AX handle. CGWindowID/title/bounds correlation does not
  // establish which AX element survived a close/reopen, so this path never writes AX.
  static func inspect(
    _ entries: [DesktopCameraJournalEntry], bootSessionID: String? = desktopBootSessionID(),
    processIdentity: (pid_t) -> DesktopProcessIdentity? = { DesktopProcessIdentity.read(pid: $0) }
  ) -> [DesktopCameraRecoveryItem] {
    entries.map { entry in
      let status: DesktopCameraRecoveryProcess
      if bootSessionID == nil {
        status = .unknownBoot
      } else if entry.bootSessionID != bootSessionID {
        status = .previousBoot
      } else if let actual = processIdentity(entry.pid) {
        status = actual == entry.processIdentity ? .sameInstance : .replaced
      } else {
        status = .exited
      }
      return DesktopCameraRecoveryItem(entry: entry, process: status)
    }
  }
}
