import CoreGraphics
import Foundation

struct Window {
  let id: UInt32
  let pid: Int32
  let layer: Int
}
func check(_ value: @autoclosure () -> Bool, _ message: String) {
  if !value() { fatalError(message) }
}
let source = CGRect(x: -100, y: 40, width: 600, height: 400)
for zoom: CGFloat in [0.5, 1, 2] {
  let image = CGRect(x: 20, y: 30, width: 600 * zoom, height: 400 * zoom)
  check(
    mappedPoint(CGPoint(x: image.midX, y: image.midY), imageRect: image, sourceRect: source)
      == CGPoint(x: 200, y: 240), "zoom mapping")
  check(
    mappedPoint(CGPoint(x: image.maxX, y: image.midY), imageRect: image, sourceRect: source) == nil,
    "half-open edge")
  let centerGlobal = mappedPoint(
    CGPoint(x: image.midX, y: image.midY), imageRect: image, sourceRect: source)
  check(
    centerGlobal.flatMap { windowBasePoint(global: $0, frame: source) } == CGPoint(x: 300, y: 200),
    "zoom to AppKit coordinates with negative screen origin")
}
check(
  mappedPoint(
    .zero, imageRect: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), sourceRect: source) == nil,
  "NaN")
check(
  windowBasePoint(
    global: CGPoint(x: 760, y: 848), frame: CGRect(x: 160, y: 748, width: 640, height: 512))
    == CGPoint(x: 600, y: 412), "AppKit window base point")
check(
  windowBasePoint(global: .zero, frame: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 1)) == nil,
  "invalid window frame")
check(
  windowBasePoint(global: .zero, frame: .zero) == nil
    && windowBasePoint(global: CGPoint(x: CGFloat.infinity, y: 0), frame: source) == nil,
  "empty frame and nonfinite point")
check(
  experimentalLocalCGPoint(
    global: CGPoint(x: 760, y: 848), frame: CGRect(x: 160, y: 748, width: 640, height: 512),
    primaryScreen: CGRect(x: 0, y: 0, width: 3440, height: 1440)) == CGPoint(x: 600, y: 1340),
  "experimental local CG point")
check(
  experimentalLocalCGPoint(
    global: .zero, frame: source, primaryScreen: CGRect(x: 0, y: 0, width: 1, height: CGFloat.nan))
    == nil,
  "experimental local CG rejects invalid primary screen")
check(validFrame(width: 1280, height: 960, rowBytes: 5120, status: 0), "valid frame")
check(!validFrame(width: 1280, height: 960, rowBytes: 5119, status: 0), "short stride")
check(!validFrame(width: 4096, height: 4096, rowBytes: 16384, status: 0), "byte cap")
check(!validFrame(width: 1280, height: 960, rowBytes: 5120, status: 1), "idle frame")
let windows = [
  Window(id: 1, pid: 42, layer: 0), Window(id: 2, pid: 42, layer: 0),
  Window(id: 1, pid: 43, layer: 0),
]
func select(_ ws: [Window], pid: Int32 = 42, id: UInt32 = 1, bundle: String? = fixtureBundleID)
  -> [Window]
{
  matchingFixtureWindows(
    ws, pid: pid, expectedPID: 42, windowID: id, bundleID: bundle, id: { $0.id }, owner: { $0.pid })
}
check(select(windows).count == 1, "exact fixture window ignores other windows and owners")
check(
  select(windows, pid: 43).isEmpty && select(windows, id: 3).isEmpty
    && select(windows, id: 0).isEmpty && select(windows, bundle: "other").isEmpty,
  "wrong process, window, or bundle")
check(select(windows + [Window(id: 1, pid: 42, layer: 0)]).count == 2, "duplicate IDs")
check(
  selectFixtureAXWindow([nil, fixtureAXMainID]) == .main(1), "main identifier among service windows"
)
check(selectFixtureAXWindow([nil]) == .missing, "missing main identifier")
check(
  selectFixtureAXWindow([fixtureAXMainID, fixtureAXMainID]) == .duplicate(2),
  "duplicate main identifier")
check(
  selectFixtureAXWindow([fixtureAXMainID, fixtureAXChildID]) == .childPresent,
  "fixture child disables input")
var handshake = FixtureHandshake(generation: 7, expectedPID: 42)
check(
  handshake.receive(Data("fixture pid=42 ".utf8), generation: 7) == .pending, "partial handshake")
check(handshake.receive(Data("window=123\n".utf8), generation: 6) == .stale, "stale chunk")
check(
  handshake.receive(Data("window=123\n".utf8), generation: 7) == .ready(123), "complete handshake")
check(
  handshake.receive(Data("fixture pid=42 window=123\n".utf8), generation: 7) == .invalid
    && handshake.windowID == nil, "duplicate handshake")
var malformed = FixtureHandshake(generation: 1, expectedPID: 42)
check(
  malformed.receive(Data("fixture pid=43 window=123\n".utf8), generation: 1) == .invalid,
  "wrong handshake PID")
var trailing = FixtureHandshake(generation: 1, expectedPID: 42)
check(
  trailing.receive(Data("fixture pid=42 window=123\nextra".utf8), generation: 1) == .invalid,
  "trailing handshake data")
var oversized = FixtureHandshake(generation: 1, expectedPID: 42)
check(
  oversized.receive(Data(repeating: 65, count: 129), generation: 1) == .invalid,
  "oversized handshake")
var badWindow = FixtureHandshake(generation: 1, expectedPID: 42)
check(
  badWindow.receive(Data("fixture pid=42 window=0\n".utf8), generation: 1) == .invalid,
  "zero window ID")
check(streamActivityFresh(last: 10, now: 10.1), "complete activity fresh")
check(streamActivityFresh(last: 11, now: 12.5), "idle activity refreshes freshness")
check(!streamActivityFresh(last: 11, now: 13), "stale stream activity")
check(
  !streamActivityFresh(last: nil, now: 13) && !streamActivityFresh(last: 20, now: 19),
  "missing or non-monotonic activity")
var session = SessionState()
let first = session.start()!
check(session.start() == nil, "duplicate start")
session.cancel()
let second = session.start()!
check(!session.isCurrent(first) && session.isCurrent(second), "stale generation")
var ax = AXCheckState()
let oldAX = ax.begin(now: 10)!
ax.invalidate()
let newAX = ax.begin(now: 11)!
check(ax.complete(oldAX, now: 11.1) == .stale, "old completion after input restart")
check(ax.complete(newAX, now: 11.2) == .accepted && ax.fresh(now: 11.3), "fresh AX success")
let nextAX = ax.begin(now: 11.3)!
check(ax.complete(newAX, now: 11.31) == .stale, "out of order completion")
check(ax.complete(nextAX, now: 11.8) == .expired && !ax.fresh(now: 11.8), "expired AX request")
let reverseAX = ax.begin(now: 12)!
check(ax.complete(reverseAX, now: 11.9) == .expired, "nonmonotonic AX request")
var focusKey = FocusKeyQueue(limit: 4)
let keyDown = FocusKeyQueue.Event(code: 1, down: true, flags: 2)
let keyRepeat = FocusKeyQueue.Event(code: 1, down: true, flags: 2)
let keyUp = FocusKeyQueue.Event(code: 1, down: false, flags: 0)
let secondDown = FocusKeyQueue.Event(code: 3, down: true, flags: 0)
check(
  focusKey.append(keyDown) && focusKey.append(keyRepeat) && focusKey.append(keyUp),
  "queue key gesture")
check(focusKey.append(secondDown) && !focusKey.append(keyUp), "bounded focus key queue")
check(focusKey.takeAll() == [keyDown, keyRepeat, keyUp, secondDown], "focus key FIFO and repeat")
check(focusKey.takeAll().isEmpty, "focus key queue drains once")
check(focusKey.append(keyDown), "focus key queued before cancellation")
focusKey.cancel()
check(focusKey.takeAll().isEmpty, "cancel drops pending focus keys")
var pressed = PressedState()
let down = CGPoint(x: 1, y: 2)
let moved = CGPoint(x: 3, y: 4)
check(pressed.mouseUp(at: moved) == nil, "unmatched mouse up")
pressed.mouseDown(down)
check(pressed.mouseUp(at: down) == down, "normal mouse up")
pressed.mouseDown(down)
check(pressed.mouseUp(at: moved) == moved, "mouse up at new in-bounds position")
pressed.mouseDown(down)
pressed.mouseMove(moved)
check(pressed.mouseUp(at: nil) == moved, "outside mouse up uses last accepted position")
pressed.mouseDown(down)
check(pressed.mouseUp() == down && pressed.mouseUp() == nil, "cancel releases once")
pressed.keyDown(4)
pressed.keyDown(7)
check(
  pressed.keyUp(4) && !pressed.keyUp(4) && pressed.takeKeys() == Set([7])
    && pressed.takeKeys().isEmpty, "key release")
print("Stage6Probe pure tests passed")
