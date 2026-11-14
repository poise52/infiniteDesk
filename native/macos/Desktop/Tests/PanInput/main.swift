import AppKit

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
  guard value() else { fatalError(message) }
}

let drag: CGEventFlags = [.maskAlternate, .maskCommand]
let scroll: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
var mapping = DesktopPanMapping()
expect(!mapping.receive(.down(100), flags: [], enabled: true).consume, "Ordinary click belongs to the app")
expect(!mapping.receive(.dragged(130), flags: drag, enabled: true).consume,
  "Adding modifiers after app mouse-down must not hijack native dragging")
expect(!mapping.receive(.down(100), flags: drag.union(.maskShift), enabled: true).consume,
  "Only the exact dedicated chord may start pan")
expect(!mapping.receive(.down(100), flags: drag, enabled: false).consume,
  "Paused or unavailable camera must preserve app input")
expect(mapping.receive(.down(100), flags: drag, enabled: true).consume, "Pan must swallow mouse-down")
let moved = mapping.receive(.dragged(130.25), flags: drag, enabled: true)
expect(moved.consume && moved.packet?.delta == -30.25 && moved.packet?.ended == false,
  "Drag right projects content right with fractional camera-left delta")
expect(mapping.receive(.modifiers, flags: [], enabled: true).packet?.ended == true,
  "Releasing the chord ends camera movement")
expect(mapping.receive(.dragged(200), flags: [], enabled: true).consume,
  "Cancelled pan must swallow remaining native drag")
expect(mapping.receive(.up, flags: [], enabled: true).consume,
  "Owned mouse-up must not leak an unmatched click to the app")
expect(!mapping.receive(.up, flags: [], enabled: true).consume, "Ownership ends exactly once")

expect(!mapping.receive(.scroll(horizontal: 0, vertical: 3, continuous: false, phase: 0, momentum: 0),
  flags: [], enabled: true).consume, "Ordinary app scroll is untouched")
let wheel = mapping.receive(.scroll(horizontal: 0, vertical: -2, continuous: false, phase: 0, momentum: 0),
  flags: scroll, enabled: true)
expect(wheel.consume && wheel.packet?.delta == 48 && wheel.packet?.ended == true,
  "Wheel fallback preserves CGEvent direction and converts line units to points")
let trackpad = mapping.receive(.scroll(horizontal: -0.625, vertical: 8, continuous: true, phase: 2, momentum: 0),
  flags: scroll, enabled: true)
expect(trackpad.packet?.delta == 0.625 && trackpad.packet?.ended == false,
  "Trackpad horizontal points take precedence over vertical movement")
expect(mapping.receive(.modifiers, flags: [], enabled: true).packet?.ended == true,
  "Scroll modifier release must finish the camera gesture")
let momentum = mapping.receive(.scroll(horizontal: -5, vertical: 0, continuous: true, phase: 0, momentum: 2),
  flags: [], enabled: true)
expect(momentum.consume && momentum.packet == nil, "Old pan momentum must neither pan nor scroll the app")
_ = mapping.receive(.scroll(horizontal: 0, vertical: 0, continuous: true, phase: 0, momentum: 4),
  flags: [], enabled: true)
expect(!mapping.receive(.scroll(horizontal: 0, vertical: 10, continuous: true, phase: 1, momentum: 0),
  flags: [], enabled: true).consume, "A new unmodified gesture belongs to the app")

_ = mapping.receive(.down(12), flags: drag, enabled: true)
expect(mapping.receive(.dragged(24), flags: drag, enabled: false).packet?.ended == true,
  "Permission or workspace loss must stop delivery during drag")
expect(mapping.receive(.up, flags: drag, enabled: false).consume, "Permission loss must release retained ownership")
mapping.reset()
expect(!mapping.ownsDrag, "Tap reset must release its internal state")
print("Desktop pan input tests passed: exact chords, fractional direction, ownership, cancellation, scroll units, momentum isolation.")

mapping.reset()
let ordinaryEvents: [DesktopPanMapping.Input] = [
  .down(100), .dragged(110), .up, .modifiers,
  .scroll(horizontal: 1, vertical: 2, continuous: false, phase: 0, momentum: 0)
]
var authorizationChecks = 0
for _ in 0..<10_000 {
  for input in ordinaryEvents {
    let beginning = mapping.beginsGesture(input, flags: [])
    if beginning { authorizationChecks += 1 }
    _ = mapping.receive(input, flags: [], enabled: true)
  }
}
expect(authorizationChecks == 0, "Ordinary global input cannot query Accessibility permission")
expect(mapping.beginsGesture(.down(1), flags: drag), "Only a dedicated drag start requests fresh authorization")
_ = mapping.receive(.down(1), flags: drag, enabled: true)
expect(!mapping.beginsGesture(.dragged(2), flags: drag), "Active drag packets use cached eligibility")
_ = mapping.receive(.up, flags: drag, enabled: true)
expect(mapping.beginsGesture(.scroll(horizontal: 1, vertical: 0, continuous: true, phase: 1, momentum: 0), flags: scroll), "Dedicated trackpad start requests fresh authorization")
_ = mapping.receive(.scroll(horizontal: 1, vertical: 0, continuous: true, phase: 1, momentum: 0), flags: scroll, enabled: true)
expect(!mapping.beginsGesture(.scroll(horizontal: 1, vertical: 0, continuous: true, phase: 2, momentum: 0), flags: scroll), "Trackpad updates cannot repeat permission IPC")
expect(mapping.beginsGesture(.scroll(horizontal: 1, vertical: 0, continuous: true, phase: 1, momentum: 0), flags: scroll), "A new gesture rechecks access even when modifiers remain held")
print("Desktop pan authorization tests passed: 50,000 ordinary events require zero permission checks; dedicated starts reauthorize once.")
