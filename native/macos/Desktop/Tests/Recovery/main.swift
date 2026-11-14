import Darwin
import Foundation

let boot = "E78732BC-D531-41A4-B2BB-0BD2A6B6A729"
let birth = DesktopProcessIdentity(seconds: 123_456, microseconds: 543_210)
let original = CGRect(x: 72, y: 100, width: 620, height: 470)
let intended = CGRect(x: 1340, y: 100, width: 620, height: 470)

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError(message) }
}

func fails(_ message: String, _ body: () throws -> Void) {
  do {
    try body()
    fatalError("Expected rejection: \(message)")
  } catch {}
}

func entry(id: UUID = UUID(), frame: CGRect = original) -> DesktopCameraJournalEntry {
  DesktopCameraJournalEntry(
    id: id, pid: 12001, processIdentity: birth, title: "Identical Chrome title",
    appName: "Google Chrome", bundleIdentifier: "com.google.Chrome", originalFrame: frame,
    bootSessionID: boot)
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--interrupt" {
  let journal = try DesktopCameraJournal(fileURL: URL(fileURLWithPath: CommandLine.arguments[2]))
  let saved = entry()
  try journal.prepare(saved)
  try journal.recordIntent(id: saved.id, frame: intended, minimized: true)
  _exit(91)
}

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-recovery-tests-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

let file = temporary.appendingPathComponent("roundtrip/recovery.json")
let a = entry()
let b = entry(frame: original.offsetBy(dx: 500, dy: 40))
do {
  let journal = try DesktopCameraJournal(fileURL: file)
  require(journal.entries.isEmpty, "Missing journal must start empty")
  try journal.prepare(a)
  try journal.prepare(b)
  fails("Second writer must not overwrite live manager recovery") {
    _ = try DesktopCameraJournal(fileURL: file)
  }
  try journal.recordIntent(id: a.id, frame: intended, minimized: true)
  require(journal.entries[0].originalFrame == original, "Camera intent cannot overwrite original bounds")
  try journal.prepare(a)
  require(journal.entries[0].lastIntendedMinimized, "Repeated prepare must preserve the durable pending mutation")
  fails("Saved original is immutable") { try journal.prepare(entry(id: a.id, frame: intended)) }
  fails("Mutation without original must be rejected") {
    try journal.recordIntent(id: UUID(), frame: intended, minimized: true)
  }
}
do {
  let journal = try DesktopCameraJournal(fileURL: file)
  require(journal.entries.count == 2, "Both same-title Chrome windows must survive reload independently")
  require(journal.entries[0].lastIntendedFrame == intended && journal.entries[0].lastIntendedMinimized,
          "Reload must include the write-ahead intended geometry and minimization")
  let report = DesktopCameraRecovery.inspect(journal.entries, bootSessionID: boot, processIdentity: { _ in birth })
  require(report.count == 2 && report.allSatisfy { $0.process == .sameInstance },
          "A live process still requires explicit recovery for each independent window")
  require(report[0].instructions.contains("Original:") && report[0].instructions.contains("Last intended:"),
          "Manual recovery must expose usable saved geometry")
  require(report[0].explanation.contains("manually"), "No frame/title heuristic may claim exact recovery")
  try journal.complete(id: a.id)
  require(journal.entries.map(\.id) == [b.id], "Confirmed restoration clears only that exact entry")
}
do {
  let journal = try DesktopCameraJournal(fileURL: file)
  require(journal.entries.map(\.id) == [b.id], "Completion must survive restart")
  try journal.complete(id: b.id)
}
do {
  let journal = try DesktopCameraJournal(fileURL: file)
  require(journal.entries.isEmpty, "An empty durable document records complete recovery")
}

let reportInput = [a, b]
let replaced = DesktopCameraRecovery.inspect(reportInput, bootSessionID: boot) { _ in
  DesktopProcessIdentity(seconds: birth.seconds + 1, microseconds: birth.microseconds)
}
require(replaced.allSatisfy { $0.process == .replaced }, "A recycled PID must never authorize recovery")
let exited = DesktopCameraRecovery.inspect(reportInput, bootSessionID: boot, processIdentity: { _ in nil })
require(exited.allSatisfy { $0.process == .exited }, "An exited process has no restorable window")
let rebooted = DesktopCameraRecovery.inspect(reportInput, bootSessionID: UUID().uuidString) { _ in birth }
require(rebooted.allSatisfy { $0.process == .previousBoot }, "Process start times cannot identify a process across boots")
let unknownBoot = DesktopCameraRecovery.inspect(reportInput, bootSessionID: nil) { _ in birth }
require(unknownBoot.allSatisfy { $0.process == .unknownBoot }, "Unknown boot identity cannot authorize recovery")

let interruptedFile = temporary.appendingPathComponent("interrupted/recovery.json")
let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
child.arguments = ["--interrupt", interruptedFile.path]
try child.run()
child.waitUntilExit()
require(child.terminationStatus == 91, "Crash fixture must terminate without journal teardown")
do {
  let journal = try DesktopCameraJournal(fileURL: interruptedFile)
  require(journal.entries.count == 1 && journal.entries[0].lastIntendedMinimized,
          "Write-ahead recovery must survive an interrupted process without deinit")
}

let invalid = temporary.appendingPathComponent("invalid.json")
try Data("{broken".utf8).write(to: invalid)
fails("Corrupt JSON must block, preserving its evidence") { _ = try DesktopCameraJournal(fileURL: invalid) }
let corruptEvidence = try Data(contentsOf: invalid)
require(corruptEvidence == Data("{broken".utf8), "Corrupt evidence must not be silently replaced")

let encoded = try JSONEncoder().encode(a)
let object = try JSONSerialization.jsonObject(with: encoded)
for (name, document) in [
  ("duplicates", ["version": 1, "entries": [object, object]] as [String: Any]),
  ("version", ["version": 2, "entries": [object]] as [String: Any]),
] {
  let url = temporary.appendingPathComponent("\(name).json")
  try JSONSerialization.data(withJSONObject: document).write(to: url)
  fails(name) { _ = try DesktopCameraJournal(fileURL: url) }
}

let invalidGeometry = entry(frame: CGRect(x: 0, y: 0, width: -1, height: 1))
do {
  let journal = try DesktopCameraJournal(fileURL: temporary.appendingPathComponent("geometry.json"))
  fails("Invalid bounds cannot precede mutation") { try journal.prepare(invalidGeometry) }
  require(journal.entries.isEmpty, "Rejected input cannot affect cache")
  try journal.prepare(a)
}

let symlink = temporary.appendingPathComponent("symlink.json")
try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
fails("Symlinked journal is not recovery evidence") { _ = try DesktopCameraJournal(fileURL: symlink) }

let failureDirectory = temporary.appendingPathComponent("failure")
let movedDirectory = temporary.appendingPathComponent("moved")
do {
  let journal = try DesktopCameraJournal(fileURL: failureDirectory.appendingPathComponent("recovery.json"))
  try journal.prepare(a)
  try FileManager.default.moveItem(at: failureDirectory, to: movedDirectory)
  try Data("not a directory".utf8).write(to: failureDirectory)
  fails("Storage failure cannot commit the in-memory removal") { try journal.complete(id: a.id) }
  require(journal.entries == [a], "Failed completion retains the recovery entry")
  try FileManager.default.removeItem(at: failureDirectory)
  try FileManager.default.moveItem(at: movedDirectory, to: failureDirectory)
  fails("A failed store cannot overwrite uncertain durable state") { try journal.complete(id: a.id) }
}
do {
  let journal = try DesktopCameraJournal(fileURL: failureDirectory.appendingPathComponent("recovery.json"))
  require(journal.entries == [a], "Prior durable original survives failed persistence")
}

print("Desktop recovery tests passed: durable pre-mutation intent, interrupted writer, exact-entry completion, identical titles, PID reuse, reboot, corrupt/duplicate/schema rejection, exclusive writer, immutable originals, safe failure, manual recovery only; zero AX writes.")
