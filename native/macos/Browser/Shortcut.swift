import AppKit

func routeFocusShortcut(
  keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool, selected: Bool,
  focus: () -> Void
) -> Bool {
  let relevant = modifiers.intersection([.command, .control, .option, .shift])
  guard selected, keyCode == 36 || keyCode == 76, relevant == [.command] else { return false }
  if !isRepeat { focus() }
  return true
}
