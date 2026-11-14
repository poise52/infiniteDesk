import AppKit
import CoreGraphics

func postFixturePan(_ request: String, target: Window, pid: pid_t, app: AXUIElement) throws -> [String: Any] {
  struct Input: Decodable {
    let kind: String
    let deltas: [Int]
    let intervalMS: Int
  }
  let input = try JSONDecoder().decode(Input.self, from: Data(request.utf8))
  let plain = input.kind == "wheel"
  let drag = input.kind == "drag"
  guard (drag || plain || input.kind == "panWheel"), (1...400).contains(input.deltas.count),
    input.deltas.allSatisfy({ (-1100...1100).contains($0) }), (1...100).contains(input.intervalMS),
    input.deltas.count * input.intervalMS <= 5500,
    let source = CGEventSource(stateID: .privateState),
    !CGEventSource.buttonState(.hidSystemState, button: .left),
    CGEventSource.flagsState(.hidSystemState).intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift]).isEmpty
  else { throw Failure.message("Fixture pan input is outside its bounds or physical input is busy") }
  let start = CGPoint(x: target.frame.midX, y: target.frame.midY + 35)
  let safe = CGDisplayBounds(CGMainDisplayID()).insetBy(dx: 20, dy: 36)
  var point = start
  for dx in input.deltas where drag {
    point.x -= CGFloat(dx)
    guard safe.contains(point) else { throw Failure.message("Fixture drag would leave the display") }
  }
  func verifyTarget() throws {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
      let current = attribute(app, kAXFocusedWindowAttribute), CFEqual(current, target.element)
    else { throw Failure.message("Fixture lost keyboard focus during the gesture") }
  }
  try verifyTarget()
  guard safe.contains(start), gestureHit(at: start, target: target.element).matches(target, pid: pid) else {
    throw Failure.message("Fixture pointer does not hit the retained original window")
  }
  point = start
  let flags: CGEventFlags = drag ? [.maskAlternate, .maskCommand] : plain ? [] : [.maskAlternate, .maskCommand, .maskControl]
  func mouse(_ type: CGEventType, modifiers: CGEventFlags? = nil) throws {
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    else { throw Failure.message("Could not create fixture mouse event") }
    event.flags = modifiers ?? flags
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
  }
  try mouse(.mouseMoved)
  Thread.sleep(forTimeInterval: 0.035)
  try verifyTarget()
  var down = false
  defer { if down { try? mouse(.leftMouseUp, modifiers: []) } }
  if drag { try mouse(.leftMouseDown); down = true }
  let started = DispatchTime.now().uptimeNanoseconds
  var samples: [[String: Double]] = []
  var lastSample = started
  for delta in input.deltas {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
      throw Failure.message("Another app took foreground during fixture input")
    }
    if drag {
      point.x -= CGFloat(delta)
      try mouse(.leftMouseDragged)
    } else {
      guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
        wheel1: -Int32(delta), wheel2: 0, wheel3: 0) else { throw Failure.message("Could not create fixture wheel event") }
      event.flags = flags
      event.location = start
      event.setIntegerValueField(.scrollWheelEventIsContinuous, value: plain ? 0 : 1)
      event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -Int64(delta))
      event.post(tap: .cghidEventTap)
    }
    let now = DispatchTime.now().uptimeNanoseconds
    if drag && now - lastSample >= 16_000_000 {
      lastSample = now
      if let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow, target.id) as? [[String: Any]],
        let info = infos.first, (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.id,
        (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
        let bounds = info[kCGWindowBounds as String] as? NSDictionary,
        let frame = CGRect(dictionaryRepresentation: bounds) {
        samples.append(["ms": Double(now - started) / 1_000_000, "x": frame.minX])
      }
    }
    Thread.sleep(forTimeInterval: Double(input.intervalMS) / 1000)
  }
  if drag { try mouse(.leftMouseUp, modifiers: []); down = false }
  else if !plain { try mouse(.mouseMoved, modifiers: []) }
  return ["kind": input.kind, "posted": input.deltas.count, "delta": input.deltas.reduce(0, +), "samples": samples]
}
