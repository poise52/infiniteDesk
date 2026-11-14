import AppKit
import ApplicationServices

enum DesktopPanSource: String, Encodable, Sendable { case drag, scroll }

struct DesktopPanPacket: Sendable {
  let delta: CGFloat
  let ended: Bool
  let source: DesktopPanSource
}

struct DesktopPanDecision {
  let consume: Bool
  let packet: DesktopPanPacket?
}

struct DesktopPanMapping {
  enum Input {
    case down(CGFloat), dragged(CGFloat), up, modifiers
    case scroll(horizontal: CGFloat, vertical: CGFloat, continuous: Bool, phase: Int64, momentum: Int64)
  }

  private(set) var ownsDrag = false
  private var dragX: CGFloat = 0
  private var dragDelivering = false
  private var ownsScroll = false
  private var scrollDelivering = false
  private let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]

  func beginsGesture(_ input: Input, flags: CGEventFlags) -> Bool {
    let chord = flags.intersection(modifiers)
    switch input {
    case .down:
      return !ownsDrag && chord == [.maskAlternate, .maskCommand]
    case .scroll(_, _, let continuous, let phase, let momentum):
      return !ownsDrag && chord == [.maskControl, .maskAlternate, .maskCommand]
        && (!ownsScroll || phase & 1 != 0 || (!continuous && phase == 0 && momentum == 0))
    default: return false
    }
  }

  mutating func receive(_ input: Input, flags: CGEventFlags, enabled: Bool) -> DesktopPanDecision {
    let chord = flags.intersection(modifiers)
    let dragChord = chord == [.maskAlternate, .maskCommand]
    let scrollChord = chord == [.maskControl, .maskAlternate, .maskCommand]
    switch input {
    case .down(let x):
      guard enabled, dragChord else { return .init(consume: false, packet: nil) }
      ownsDrag = true
      dragDelivering = true
      dragX = x
      return .init(consume: true, packet: nil)
    case .dragged(let x):
      guard ownsDrag else { return .init(consume: false, packet: nil) }
      let delta = dragX - x
      dragX = x
      guard dragDelivering else { return .init(consume: true, packet: nil) }
      if !enabled || !dragChord {
        dragDelivering = false
        return .init(consume: true, packet: .init(delta: 0, ended: true, source: .drag))
      }
      return .init(consume: true, packet: delta == 0 ? nil : .init(delta: delta, ended: false, source: .drag))
    case .up:
      guard ownsDrag else { return .init(consume: false, packet: nil) }
      ownsDrag = false
      let ended = dragDelivering
      dragDelivering = false
      return .init(consume: true, packet: ended ? .init(delta: 0, ended: true, source: .drag) : nil)
    case .modifiers:
      if dragDelivering, !dragChord || !enabled {
        dragDelivering = false
        return .init(consume: false, packet: .init(delta: 0, ended: true, source: .drag))
      }
      if scrollDelivering, !scrollChord || !enabled {
        scrollDelivering = false
        // Retain ownership until the old trackpad momentum stops, so it cannot scroll the app.
        return .init(consume: false, packet: .init(delta: 0, ended: true, source: .scroll))
      }
      return .init(consume: false, packet: nil)
    case .scroll(let horizontal, let vertical, let continuous, let phase, let momentum):
      if ownsScroll, momentum != 0, (!enabled || !scrollChord) {
        if momentum & 4 != 0 { ownsScroll = false }
        return .init(consume: true, packet: nil)
      }
      guard enabled, scrollChord, !ownsDrag else {
        ownsScroll = false
        scrollDelivering = false
        return .init(consume: false, packet: nil)
      }
      let axis = horizontal != 0 ? horizontal : vertical
      let delta = -axis * (continuous ? 1 : 24)
      let ended = phase & 12 != 0 || momentum & 4 != 0 || (!continuous && phase == 0 && momentum == 0)
      ownsScroll = continuous && (momentum != 4)
      scrollDelivering = !ended
      return .init(consume: true, packet: .init(delta: delta, ended: ended, source: .scroll))
    }
  }

  mutating func reset() { self = Self() }
}

@MainActor
final class DesktopPanInput {
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var mapping = DesktopPanMapping()
  private let enabled: () -> Bool
  private let authorize: () -> Bool
  private let action: (DesktopPanPacket) -> Void
  private let statusChanged: (String?) -> Void

  init(enabled: @escaping () -> Bool, authorize: @escaping () -> Bool = { AXIsProcessTrusted() },
    action: @escaping (DesktopPanPacket) -> Void,
    statusChanged: @escaping (String?) -> Void) {
    self.enabled = enabled
    self.authorize = authorize
    self.action = action
    self.statusChanged = statusChanged
  }

  func start() {
    stop()
    guard AXIsProcessTrusted() else {
      statusChanged("Continuous pan needs Accessibility. Grant access, then Retry global input.")
      return
    }
    let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel, .flagsChanged]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
      options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        // This tap's source is installed exclusively on the main run loop.
        let consume = MainActor.assumeIsolated {
          Unmanaged<DesktopPanInput>.fromOpaque(context).takeUnretainedValue().receive(type, event)
        }
        return consume ? nil : Unmanaged.passUnretained(event)
      }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
      statusChanged("Continuous pan unavailable. Check Accessibility and Retry global input; page shortcuts still work.")
      return
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      CFMachPortInvalidate(tap)
      statusChanged("Continuous pan could not create its event source. Retry global input.")
      return
    }
    self.tap = tap
    self.source = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    statusChanged(nil)
  }

  func stop() {
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    if let tap { CFMachPortInvalidate(tap) }
    tap = nil
    source = nil
    mapping.reset()
  }

  func checkHealth() {
    guard AXIsProcessTrusted() else {
      stop()
      statusChanged("Continuous pan stopped: Accessibility was revoked. Grant access and Retry global input.")
      return
    }
    if let tap, !CGEvent.tapIsEnabled(tap: tap) {
      statusChanged("Continuous pan event tap is disabled. Retry global input.")
    }
  }

  private func receive(_ type: CGEventType, _ event: CGEvent) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      mapping.reset()
      action(.init(delta: 0, ended: true, source: .drag))
      if type == .tapDisabledByTimeout, AXIsProcessTrusted(), let tap {
        CGEvent.tapEnable(tap: tap, enable: true)
        statusChanged("Pan interrupted by event-tap timeout; release the mouse and start the gesture again.")
      } else {
        stop()
        statusChanged("Continuous pan event tap stopped. Release the mouse, then Retry global input.")
      }
      return false
    }
    let input: DesktopPanMapping.Input
    switch type {
    case .leftMouseDown: input = .down(event.location.x)
    case .leftMouseDragged: input = .dragged(event.location.x)
    case .leftMouseUp: input = .up
    case .flagsChanged: input = .modifiers
    case .scrollWheel:
      let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
      input = .scroll(
        horizontal: CGFloat(event.getDoubleValueField(continuous ? .scrollWheelEventPointDeltaAxis2 : .scrollWheelEventDeltaAxis2)),
        vertical: CGFloat(event.getDoubleValueField(continuous ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventDeltaAxis1)),
        continuous: continuous, phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
        momentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase))
    default: return false
    }
    let ready = enabled()
    let beginning = mapping.beginsGesture(input, flags: event.flags)
    let allowed = ready && (!beginning || authorize())
    let decision = mapping.receive(input, flags: event.flags, enabled: allowed)
    if let packet = decision.packet { action(packet) }
    return decision.consume
  }
}
