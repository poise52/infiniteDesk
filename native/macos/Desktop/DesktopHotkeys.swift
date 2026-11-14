import AppKit
import Carbon

enum DesktopShortcut: UInt32, CaseIterable {
  case register = 1
  case previous = 2
  case next = 3

  var keyCode: UInt32 {
    switch self {
    case .register: UInt32(kVK_ANSI_W)
    case .previous: UInt32(kVK_LeftArrow)
    case .next: UInt32(kVK_RightArrow)
    }
  }

  var label: String {
    switch self {
    case .register: "⌃⌥⌘W"
    case .previous: "⌃⌥⌘←"
    case .next: "⌃⌥⌘→"
    }
  }
}

@MainActor
final class DesktopHotkeys {
  private static let signature: OSType = 0x4944534B
  private var handler: EventHandlerRef?
  private var references: [EventHotKeyRef] = []
  private let action: (DesktopShortcut) -> Void

  init(action: @escaping (DesktopShortcut) -> Void) {
    self.action = action
  }

  func start() -> String? {
    stop()
    var event = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let installed = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let result = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard result == noErr else { return result }
        // Application event handlers are dispatched by NSApplication's main event loop.
        return MainActor.assumeIsolated {
          guard identifier.signature == DesktopHotkeys.signature,
            let shortcut = DesktopShortcut(rawValue: identifier.id)
          else { return OSStatus(eventNotHandledErr) }
          Unmanaged<DesktopHotkeys>.fromOpaque(context).takeUnretainedValue().action(shortcut)
          return noErr
        }
      }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    guard installed == noErr else {
      return "Global shortcuts unavailable (event handler: \(installed)). Use the menu."
    }
    var unavailable: [String] = []
    for shortcut in DesktopShortcut.allCases {
      var reference: EventHotKeyRef?
      let result = RegisterEventHotKey(
        shortcut.keyCode, UInt32(controlKey | optionKey | cmdKey),
        EventHotKeyID(signature: Self.signature, id: shortcut.rawValue),
        GetApplicationEventTarget(), 0, &reference)
      if result == noErr, let reference {
        references.append(reference)
      } else {
        unavailable.append("\(shortcut.label) (\(result))")
      }
    }
    return unavailable.isEmpty
      ? nil : "Shortcut unavailable: \(unavailable.joined(separator: ", ")). Use the menu."
  }

  func stop() {
    for reference in references { UnregisterEventHotKey(reference) }
    references.removeAll()
    if let handler { RemoveEventHandler(handler) }
    handler = nil
  }
}
