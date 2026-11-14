import AppKit
import ApplicationServices
import OSLog

@MainActor
final class DesktopApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let logger = Logger(subsystem: "dev.infinitedesk.desktop", category: "focus")
  private let client = DesktopWindowClient()
  private var statusItem: NSStatusItem?
  private let menu = NSMenu()
  private var hotkeys: DesktopHotkeys?
  private var menuApplication: DesktopApplicationSnapshot?
  private var selectedID: UUID?
  private var cycleCursorID: UUID?
  private var registrationNumbers: [UUID: Int] = [:]
  private var nextRegistrationNumber = 1
  private var trusted = DesktopWindowClient.accessibilityTrusted
  private var status = "Register a focused window to begin."
  private var shortcutWarning: String?

  func applicationDidFinishLaunching(_ notification: Notification) {
    logger.info("manager launched pid=\(ProcessInfo.processInfo.processIdentifier) trusted=\(self.trusted) windows=\(self.client.windows.count)")
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = "InfiniteDeskDesktop"
    if let image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "InfiniteDesk") {
      item.button?.image = image
    } else {
      item.button?.title = "ID"
    }
    item.button?.setAccessibilityLabel("InfiniteDesk window manager")
    item.button?.toolTip = "InfiniteDesk — desktop window manager"
    item.menu = menu
    statusItem = item
    menu.delegate = self
    menu.autoenablesItems = false
    let hotkeys = DesktopHotkeys { [weak self] shortcut in
      self?.handle(shortcut)
    }
    self.hotkeys = hotkeys
    shortcutWarning = hotkeys.start()
    updateMenu()
  }

  func applicationWillTerminate(_ notification: Notification) {
    hotkeys?.stop()
    hotkeys = nil
    client.close()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func menuWillOpen(_ menu: NSMenu) {
    menuApplication = externalApplication()
    checkPermission()
    updateMenu()
  }

  private func externalApplication() -> DesktopApplicationSnapshot? {
    guard let application = NSWorkspace.shared.frontmostApplication,
      application.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else { return nil }
    return DesktopWindowClient.snapshot(application)
  }

  private func checkPermission() {
    let current = DesktopWindowClient.accessibilityTrusted
    guard trusted != current else { return }
    trusted = current
    if !current {
      client.cancel()
      cycleCursorID = nil
      status = "Accessibility permission is required."
    } else {
      status = "Accessibility enabled. Register a focused window."
    }
    updateMenu()
  }

  private func handle(_ shortcut: DesktopShortcut) {
    logCommand(shortcut.label, source: "global")
    switch shortcut {
    case .register: register(application: externalApplication())
    case .previous: cycle(direction: -1)
    case .next: cycle(direction: 1)
    }
  }

  private func register(application: DesktopApplicationSnapshot?) {
    guard requirePermission() else { return }
    guard let application else {
      logger.error("capture rejected reason=no_frontmost_application windows=\(self.client.windows.count)")
      status = "Focus another application's window, then press \(DesktopShortcut.register.label)."
      updateMenu()
      return
    }
    cycleCursorID = nil
    logger.info("capture begin pid=\(application.pid) windows=\(self.client.windows.count)")
    status = "Registering the focused window of \(application.appName)…"
    updateMenu()
    client.captureFocused(application: application) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let window):
        if self.registrationNumbers[window.id] == nil {
          self.registrationNumbers[window.id] = self.nextRegistrationNumber
          self.nextRegistrationNumber += 1
        }
        self.logger.info("capture result=success pid=\(window.pid) number=\(self.registrationNumbers[window.id] ?? 0) windows=\(self.client.windows.count)")
        self.selectedID = window.id
        self.status = "Registered: \(self.label(window))"
      case .failure(let error):
        self.logger.error("capture result=failure pid=\(application.pid) reason=\(error.localizedDescription, privacy: .public) windows=\(self.client.windows.count)")
        self.status = error.localizedDescription
      }
      self.updateMenu()
    }
  }

  private func cycle(direction: Int) {
    guard requirePermission() else { return }
    let windows = client.windows
    guard !windows.isEmpty else {
      logger.error("cycle rejected reason=no_registered_windows direction=\(direction) windows=0")
      status = "No registered windows. Press \(DesktopShortcut.register.label) in a window."
      updateMenu()
      return
    }
    let origin = cycleCursorID ?? selectedID
    let index: Int
    if let current = windows.firstIndex(where: { $0.id == origin }) {
      index = (current + direction + windows.count) % windows.count
    } else {
      index = direction > 0 ? 0 : windows.count - 1
    }
    select(id: windows[index].id)
  }

  private func select(id: UUID) {
    guard requirePermission(), let window = client.windows.first(where: { $0.id == id }) else { return }
    cycleCursorID = id
    logger.info("focus begin pid=\(window.pid) number=\(self.registrationNumbers[id] ?? 0) windows=\(self.client.windows.count)")
    status = "Focusing: \(label(window))…"
    updateMenu()
    client.focus(id: id) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let focused):
        self.logger.info("focus result=success pid=\(focused.pid) number=\(self.registrationNumbers[id] ?? 0) windows=\(self.client.windows.count)")
        self.selectedID = focused.id
        self.status = "Focused: \(self.label(focused))"
      case .failure(let error):
        self.logger.error("focus result=failure pid=\(window.pid) number=\(self.registrationNumbers[id] ?? 0) reason=\(error.localizedDescription, privacy: .public) windows=\(self.client.windows.count)")
        self.status = error.localizedDescription
      }
      self.updateMenu()
    }
  }

  private func requirePermission() -> Bool {
    checkPermission()
    guard trusted else {
      logger.error("command rejected reason=accessibility_denied windows=\(self.client.windows.count)")
      status = "Allow InfiniteDesk in Privacy & Security → Accessibility."
      updateMenu()
      return false
    }
    return true
  }

  private func logCommand(_ command: String, source: String) {
    logger.info("command received command=\(command, privacy: .public) source=\(source, privacy: .public) windows=\(self.client.windows.count)")
  }

  private func label(_ window: DesktopWindow) -> String {
    let number = registrationNumbers[window.id] ?? 0
    return "\(number). \(window.appName) — \(window.title.isEmpty ? "Untitled window" : window.title)"
  }

  private func updateMenu() {
    menu.removeAllItems()
    append("InfiniteDesk · \(client.windows.count) registered", enabled: false)
    append(trusted ? "Accessibility: enabled" : "Accessibility: permission required", enabled: false)
    let messageItem = append(status, enabled: false)
    messageItem.toolTip = status
    if let shortcutWarning {
      let warning = append(shortcutWarning, enabled: false)
      warning.toolTip = shortcutWarning
    }
    menu.addItem(.separator())
    append("Register focused window", action: #selector(registerFromMenu), enabled: trusted,
      shortcut: .register)
    append("Previous window", action: #selector(previousFromMenu), enabled: trusted && !client.windows.isEmpty,
      shortcut: .previous)
    append("Next window", action: #selector(nextFromMenu), enabled: trusted && !client.windows.isEmpty,
      shortcut: .next)
    menu.addItem(.separator())
    if client.windows.isEmpty {
      append("No registered windows", enabled: false)
    } else {
      for window in client.windows {
        let item = append(label(window), action: #selector(selectFromMenu(_:)), enabled: trusted)
        item.representedObject = window.id.uuidString
        item.state = selectedID == window.id ? .on : .off
        item.toolTip = "PID \(window.pid) · \(window.originalFrame)"
      }
      let forgetItem = append("Forget registered window")
      let forgetMenu = NSMenu(title: "Forget registered window")
      forgetMenu.autoenablesItems = false
      for window in client.windows {
        let item = NSMenuItem(title: label(window), action: #selector(forgetFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = window.id.uuidString
        forgetMenu.addItem(item)
      }
      forgetItem.submenu = forgetMenu
    }
    menu.addItem(.separator())
    append("Request Accessibility permission…", action: #selector(requestPermission), enabled: !trusted)
    append("Open Accessibility settings…", action: #selector(openAccessibility))
    append("Retry global shortcuts", action: #selector(retryShortcuts))
    menu.addItem(.separator())
    append("Quit InfiniteDesk", action: #selector(quit))
    statusItem?.button?.toolTip = "InfiniteDesk — \(status)"
  }

  @discardableResult
  private func append(
    _ title: String, action: Selector? = nil, enabled: Bool = true,
    shortcut: DesktopShortcut? = nil
  ) -> NSMenuItem {
    let displayTitle = shortcut.map { "\(title)  (\($0.label))" } ?? title
    let item = NSMenuItem(title: displayTitle, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = enabled
    menu.addItem(item)
    return item
  }

  @objc private func registerFromMenu() {
    logCommand("register", source: "menu")
    register(application: menuApplication)
  }
  @objc private func previousFromMenu() {
    logCommand("previous", source: "menu")
    cycle(direction: -1)
  }
  @objc private func nextFromMenu() {
    logCommand("next", source: "menu")
    cycle(direction: 1)
  }
  @objc private func selectFromMenu(_ item: NSMenuItem) {
    guard let value = item.representedObject as? String, let id = UUID(uuidString: value) else { return }
    logCommand("focus", source: "menu")
    select(id: id)
  }
  @objc private func forgetFromMenu(_ item: NSMenuItem) {
    guard let value = item.representedObject as? String, let id = UUID(uuidString: value),
      let window = client.windows.first(where: { $0.id == id })
    else { return }
    let removedLabel = label(window)
    client.remove(id: id)
    cycleCursorID = nil
    if selectedID == id { selectedID = nil }
    registrationNumbers.removeValue(forKey: id)
    status = "Forgot: \(removedLabel)"
    updateMenu()
  }
  @objc private func requestPermission() {
    DesktopWindowClient.requestAccessibility()
    checkPermission()
  }
  @objc private func openAccessibility() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
    if !NSWorkspace.shared.open(url) {
      status = "Open System Settings → Privacy & Security → Accessibility."
      updateMenu()
    }
  }
  @objc private func retryShortcuts() {
    shortcutWarning = hotkeys?.start()
    updateMenu()
  }
  @objc private func quit() { NSApp.terminate(nil) }
}
