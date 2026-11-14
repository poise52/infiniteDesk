import AppKit

@MainActor final class FixtureContent: NSView {
  private let counter = NSButton(title: "Clicks: 0", target: nil, action: nil)
  private var clicks = 0

  init(name: String) {
    super.init(frame: .zero)
    counter.target = self
    counter.action = #selector(countClick)
    let editor = NSTextField(string: "Editable \(name)")
    editor.setAccessibilityLabel("Editor \(name)")
    let scroll = NSTextView.scrollableTextView()
    guard let document = scroll.documentView as? NSTextView else {
      preconditionFailure("NSTextView.scrollableTextView() must contain an NSTextView")
    }
    document.isEditable = false
    document.isRichText = false
    document.textContainerInset = NSSize(width: 4, height: 4)
    document.string = (1...100).map { "Window \(name) — row \($0)" }.joined(separator: "\n")
    document.scrollRangeToVisible(NSRange(location: 0, length: 0))
    scroll.borderType = .bezelBorder
    for child in [editor, counter, scroll] as [NSView] {
      child.translatesAutoresizingMaskIntoConstraints = false
      addSubview(child)
    }
    NSLayoutConstraint.activate([
      editor.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      editor.trailingAnchor.constraint(equalTo: counter.leadingAnchor, constant: -8),
      editor.centerYAnchor.constraint(equalTo: counter.centerYAnchor),
      counter.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      counter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      scroll.leadingAnchor.constraint(equalTo: editor.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: counter.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: counter.bottomAnchor, constant: 6),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
    ])
  }

  required init?(coder: NSCoder) { nil }

  @objc private func countClick() {
    clicks += 1
    counter.title = "Clicks: \(clicks)"
  }
}

@MainActor final class Fixture: NSObject, NSApplicationDelegate {
  var windows: [NSWindow] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    for (name, origin) in [("A", NSPoint(x: 140, y: 200)), ("B", NSPoint(x: 540, y: 200))] {
      let window = NSWindow(
        contentRect: NSRect(origin: origin, size: NSSize(width: 340, height: 240)),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
        defer: false)
      window.isReleasedWhenClosed = false
      window.contentMinSize = NSSize(width: 180, height: 100)
      window.title = "InfiniteDesk Focus Fixture \(name)"
      window.contentView = FixtureContent(name: name)
      if name == "B", ProcessInfo.processInfo.environment["INFINITEDESK_TALL_FIXTURE"] == "1",
        let screen = NSScreen.screens.first?.visibleFrame
      {
        window.setFrame(
          NSRect(
            x: screen.minX + 49, y: screen.minY - 60,
            width: min(1200, screen.width - 80), height: screen.height - 20), display: true)
      }
      window.makeKeyAndOrderFront(nil)
      windows.append(window)
    }
    NSApp.activate()
    if let idPath = CommandLine.arguments.dropFirst().first {
      let ids = windows.map { String($0.windowNumber) }.joined(separator: " ") + "\n"
      do { try ids.write(toFile: idPath, atomically: true, encoding: .utf8) } catch {
        FileHandle.standardError.write(Data("Could not write fixture IDs: \(error)\n".utf8))
        exit(1)
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let menu = NSMenu()
let appMenu = NSMenu()
appMenu.addItem(
  withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let edit = NSMenu(title: "Edit")
edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
for submenu in [appMenu, edit] {
  let item = NSMenuItem()
  item.submenu = submenu
  menu.addItem(item)
}
app.mainMenu = menu
let delegate = Fixture()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
