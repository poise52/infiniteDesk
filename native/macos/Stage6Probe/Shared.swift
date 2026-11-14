import CoreGraphics
import Foundation

let fixtureBundleID = "org.infinitedesk.stage6.fixture"
let fixtureAXMainID = "org.infinitedesk.stage6.fixture.main"
let fixtureAXChildID = "org.infinitedesk.stage6.fixture.child"

enum FixtureAXSelection: Equatable {
  case main(Int)
  case missing
  case duplicate(Int)
  case childPresent
}
func selectFixtureAXWindow(_ identifiers: [String?]) -> FixtureAXSelection {
  if identifiers.contains(where: { $0 == fixtureAXChildID }) { return .childPresent }
  let candidates = identifiers.indices.filter { identifiers[$0] == fixtureAXMainID }
  if candidates.isEmpty { return .missing }
  if candidates.count > 1 { return .duplicate(candidates.count) }
  return .main(candidates[0])
}

func matchingFixtureWindows<T>(
  _ windows: [T], pid: Int32, expectedPID: Int32, windowID: UInt32, bundleID: String?,
  id: (T) -> UInt32, owner: (T) -> Int32?
) -> [T] {
  guard pid > 0, pid == expectedPID, windowID != 0, bundleID == fixtureBundleID else { return [] }
  return windows.filter { owner($0) == pid && id($0) == windowID }
}

struct FixtureHandshake {
  enum Result: Equatable {
    case pending
    case ready(UInt32)
    case invalid, stale
  }
  let generation: Int
  let expectedPID: Int32
  private var buffer = Data()
  private(set) var windowID: UInt32?
  private(set) var failed = false
  init(generation: Int, expectedPID: Int32) {
    self.generation = generation
    self.expectedPID = expectedPID
  }
  mutating func receive(_ data: Data, generation: Int) -> Result {
    guard generation == self.generation else { return .stale }
    guard !failed, windowID == nil, !data.isEmpty, buffer.count + data.count <= 128 else {
      failed = true
      windowID = nil
      return .invalid
    }
    buffer.append(data)
    guard let newline = buffer.firstIndex(of: 10) else { return .pending }
    guard newline == buffer.index(before: buffer.endIndex),
      let line = String(data: buffer.prefix(upTo: newline), encoding: .utf8)
    else {
      failed = true
      return .invalid
    }
    let fields = line.split(separator: " ", omittingEmptySubsequences: false)
    guard fields.count == 3, fields[0] == "fixture", fields[1].hasPrefix("pid="),
      fields[2].hasPrefix("window="),
      let pid = Int32(fields[1].dropFirst(4)), pid > 0, pid == expectedPID,
      let id = UInt32(fields[2].dropFirst(7)), id > 0
    else {
      failed = true
      return .invalid
    }
    windowID = id
    buffer.removeAll()
    return .ready(id)
  }
}

func mappedPoint(_ point: CGPoint, imageRect: CGRect, sourceRect: CGRect) -> CGPoint? {
  guard
    [
      point.x, point.y, imageRect.minX, imageRect.minY, imageRect.width, imageRect.height,
      sourceRect.minX, sourceRect.minY, sourceRect.width, sourceRect.height,
    ].allSatisfy(\.isFinite),
    imageRect.width > 0, imageRect.height > 0, sourceRect.width > 0, sourceRect.height > 0,
    point.x >= imageRect.minX, point.x < imageRect.maxX,
    point.y >= imageRect.minY, point.y < imageRect.maxY
  else { return nil }
  let x = (point.x - imageRect.minX) / imageRect.width
  let y = (point.y - imageRect.minY) / imageRect.height
  let result = CGPoint(
    x: sourceRect.minX + x * sourceRect.width, y: sourceRect.minY + y * sourceRect.height)
  return result.x.isFinite && result.y.isFinite ? result : nil
}

func windowBasePoint(global: CGPoint, frame: CGRect) -> CGPoint? {
  guard
    [global.x, global.y, frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
    frame.width > 0, frame.height > 0
  else { return nil }
  let result = CGPoint(x: global.x - frame.minX, y: frame.height - (global.y - frame.minY))
  return result.x.isFinite && result.y.isFinite ? result : nil
}

func experimentalLocalCGPoint(global: CGPoint, frame: CGRect, primaryScreen: CGRect) -> CGPoint? {
  guard let local = windowBasePoint(global: global, frame: frame),
    [primaryScreen.minX, primaryScreen.minY, primaryScreen.width, primaryScreen.height].allSatisfy(
      \.isFinite),
    primaryScreen.width > 0, primaryScreen.height > 0, primaryScreen.maxY.isFinite
  else { return nil }
  let point = CGPoint(x: local.x, y: primaryScreen.maxY - (global.y - frame.minY))
  return point.x.isFinite && point.y.isFinite ? point : nil
}

func validFrame(width: Int, height: Int, rowBytes: Int, status: Int) -> Bool {
  width > 0 && height > 0 && width <= 4096 && height <= 4096 && rowBytes >= width * 4
    && rowBytes <= 65536 && rowBytes * height <= 32 * 1024 * 1024 && status == 0
}

func streamActivityFresh(last: TimeInterval?, now: TimeInterval) -> Bool {
  guard let last, last.isFinite, now.isFinite, now >= last else { return false }
  return now - last < 2
}

struct SessionState {
  private(set) var generation = 0
  private(set) var busy = false
  mutating func start() -> Int? {
    guard !busy else { return nil }
    busy = true
    generation += 1
    return generation
  }
  mutating func cancel() {
    generation += 1
    busy = false
  }
  func isCurrent(_ value: Int) -> Bool { busy && generation == value }
}
struct AXCheckState {
  struct Request: Equatable {
    let id: UInt64
    let startedAt: TimeInterval
  }
  enum Completion: Equatable { case stale, expired, accepted }
  private var nextID: UInt64 = 0
  private var pending: Request?
  private(set) var checkedAt: TimeInterval?

  mutating func invalidate() {
    pending = nil
    checkedAt = nil
  }
  mutating func begin(now: TimeInterval) -> Request? {
    guard now.isFinite, pending == nil,
      checkedAt.map({ now >= $0 && now - $0 >= 0.2 }) ?? true
    else { return nil }
    nextID &+= 1
    let request = Request(id: nextID, startedAt: now)
    pending = request
    return request
  }
  mutating func complete(_ request: Request, now: TimeInterval) -> Completion {
    guard pending == request else { return .stale }
    pending = nil
    guard now.isFinite, now >= request.startedAt, now - request.startedAt < 0.5 else {
      checkedAt = nil
      return .expired
    }
    checkedAt = request.startedAt
    return .accepted
  }
  func fresh(now: TimeInterval) -> Bool {
    guard let checkedAt, now.isFinite, now >= checkedAt else { return false }
    return now - checkedAt < 0.5
  }
}
struct PressedState {
  private(set) var mouse: CGPoint?
  private(set) var keys: Set<UInt16> = []
  mutating func mouseDown(_ point: CGPoint) { mouse = point }
  mutating func mouseMove(_ point: CGPoint) { if mouse != nil { mouse = point } }
  mutating func mouseUp(at point: CGPoint? = nil) -> CGPoint? {
    guard let last = mouse else { return nil }
    mouse = nil
    return point ?? last
  }
  mutating func keyDown(_ key: UInt16) { keys.insert(key) }
  mutating func keyUp(_ key: UInt16) -> Bool { keys.remove(key) != nil }
  mutating func takeKeys() -> Set<UInt16> {
    defer { keys.removeAll() }
    return keys
  }
}
