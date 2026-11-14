import AppKit
import ApplicationServices
import OSLog

@MainActor
final class DesktopApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let logger = Logger(subsystem: "dev.infinitedesk.desktop", category: "focus")
  private let client = DesktopWindowClient()
  private let testState = DesktopTestState.configured()
  private var statusItem: NSStatusItem?
  private let menu = NSMenu()
  private var hotkeys: DesktopHotkeys?
  private var panInput: DesktopPanInput?
  private let overview = DesktopOverviewController()
  private var menuApplication: DesktopApplicationSnapshot?
  private var selectedID: UUID?
  private var cycleCursorID: UUID?
  private var pendingFocusID: UUID?
  private var observedFocusedID: UUID?
  private var registrationNumbers: [UUID: Int] = [:]
  private var nextRegistrationNumber = 1
  private var trusted = DesktopWindowClient.accessibilityTrusted
  private var status = "Register a focused window to begin."
  private var shortcutWarning: String?
  private var panWarning: String?
  private var terminating = false

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
    if testState != nil { overview.onChange = { [weak self] in self?.exportTestState() } }
    menu.delegate = self
    menu.autoenablesItems = false
    client.onChange = { [weak self] in self?.modelDidChange() }
    client.setAccessibilityTrusted(trusted)
    let hotkeys = DesktopHotkeys { [weak self] shortcut in
      self?.handle(shortcut)
    }
    self.hotkeys = hotkeys
    shortcutWarning = hotkeys.start()
    let panInput = DesktopPanInput(enabled: { [weak self] in
      guard let self else { return false }
      return self.trusted && !self.terminating && !self.overview.isVisible && !self.client.camera.paused
        && self.client.camera.recoveryCount == 0 && !self.client.windows.isEmpty
    }, authorize: { [weak self] in self?.requirePermission() ?? false },
    action: { [weak self] packet in self?.pan(packet) }, statusChanged: { [weak self] warning in
      self?.panWarning = warning
      self?.updateStatus()
    })
    self.panInput = panInput
    panInput.start()
    modelDidChange()
    updateStatus()
  }

  func applicationWillTerminate(_ notification: Notification) {
    client.onChange = nil
    testState?.stop()
    hotkeys?.stop()
    hotkeys = nil
    panInput?.stop()
    panInput = nil
    client.close()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminating else { return .terminateLater }
    terminating = true
    overview.cancel()
    status = "Restoring managed windows before quitting…"
    updateStatus()
    client.restoreForQuit { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { sender.reply(toApplicationShouldTerminate: false); return }
        switch result {
        case .success:
          sender.reply(toApplicationShouldTerminate: true)
        case .failure(let error):
          self.terminating = false
          self.status = "Quit cancelled: \(error.localizedDescription)"
          self.updateStatus()
          let alert = NSAlert()
          alert.messageText = "Could not restore every managed window"
          alert.informativeText = error.localizedDescription
            + " InfiniteDesk is still running. Restore the windows and retry Quit."
          alert.addButton(withTitle: "Keep InfiniteDesk running")
          alert.runModal()
          sender.reply(toApplicationShouldTerminate: false)
        }
      }
    }
    return .terminateLater
  }

  func menuWillOpen(_ menu: NSMenu) {
    menuApplication = externalApplication()
    checkPermission()
    panInput?.checkHealth()
    rebuildMenu()
  }

  private func modelDidChange() {
    if overview.isVisible {
      if client.camera.paused || client.camera.recoveryCount > 0 || !trusted {
        overview.cancel()
      } else {
        overview.update(windows: client.windows, camera: client.camera)
      }
    }
    if observedFocusedID != client.focusedID {
      observedFocusedID = client.focusedID
      if let focusedID = client.focusedID, pendingFocusID == nil {
        selectedID = focusedID
        cycleCursorID = nil
      }
    }
    exportTestState()
    updateStatus()
  }

  private func exportTestState() {
    testState?.publish(windows: client.windows, focusedID: client.focusedID,
      camera: client.camera, busy: client.isCameraBusy, pan: client.panMetrics,
      overview: .init(visible: overview.isVisible, isKey: overview.isKey,
        selectedID: overview.selectedID, windowNumber: overview.windowNumber))
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
    client.setAccessibilityTrusted(current)
    if !current {
      overview.cancel()
      panInput?.stop()
      panWarning = "Continuous pan stopped: Accessibility permission is required."
      client.cancel()
      cycleCursorID = nil
      pendingFocusID = nil
      status = "Accessibility permission is required."
    } else {
      panInput?.start()
      status = "Accessibility enabled. Register a focused window."
    }
    updateStatus()
  }

  private func handle(_ shortcut: DesktopShortcut) {
    logCommand(shortcut.label, source: "global")
    if overview.isVisible && shortcut != .overview {
      if shortcut == .pause { overview.cancel(); togglePause() }
      return
    }
    switch shortcut {
    case .register: register(application: externalApplication())
    case .previous: cycle(direction: -1)
    case .next: cycle(direction: 1)
    case .moveToNewPage: moveToNewPage()
    case .previousPage: changePage(by: -1)
    case .nextPage: changePage(by: 1)
    case .pause: togglePause()
    case .overview: toggleOverview()
    }
  }

  @objc private func toggleOverview() {
    if overview.isVisible { overview.cancel(); return }
    guard requirePermission(), !client.isCameraBusy, !client.camera.paused, client.camera.recoveryCount == 0 else {
      status = "Overview is available while the workspace is active."
      updateStatus()
      return
    }
    let windows = client.windows
    guard windows.contains(where: { $0.availability == .available || $0.managerMinimized }) else {
      status = "Register a window to open the workspace overview."
      updateStatus()
      return
    }
    let shown = overview.show(windows: windows, camera: client.camera, focusedID: client.focusedID,
      backToFront: desktopOverviewWindowOrder(windows: windows, origin: client.camera.origin),
      onSelect: { [weak self] id in self?.select(id: id, fromOverview: true) },
      onCancel: { [weak self] in self?.updateStatus() })
    if !shown { status = "Overview requires one active display."; updateStatus() }
  }

  private func register(application: DesktopApplicationSnapshot?) {
    guard requirePermission() else { return }
    guard let application else {
      logger.error("capture rejected reason=no_frontmost_application windows=\(self.client.windows.count)")
      status = "Focus another application's window, then press \(DesktopShortcut.register.label)."
      updateStatus()
      return
    }
    cycleCursorID = nil
    pendingFocusID = nil
    logger.info("capture begin pid=\(application.pid) windows=\(self.client.windows.count)")
    status = "Registering the focused window of \(application.appName)…"
    updateStatus()
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
      self.updateStatus()
    }
  }

  private func cycle(direction: Int) {
    guard requirePermission() else { return }
    let windows = client.windows
    guard !windows.isEmpty else {
      logger.error("cycle rejected reason=no_registered_windows direction=\(direction) windows=0")
      status = "No registered windows. Press \(DesktopShortcut.register.label) in a window."
      updateStatus()
      return
    }
    let origin = cycleCursorID ?? client.focusedID ?? selectedID
    let index: Int
    if let current = windows.firstIndex(where: { $0.id == origin }) {
      index = (current + direction + windows.count) % windows.count
    } else {
      index = direction > 0 ? 0 : windows.count - 1
    }
    select(id: windows[index].id)
  }

  private func select(id: UUID, fromOverview: Bool = false) {
    guard requirePermission(), let window = client.windows.first(where: { $0.id == id }) else { return }
    cycleCursorID = id
    pendingFocusID = id
    logger.info("focus begin pid=\(window.pid) number=\(self.registrationNumbers[id] ?? 0) windows=\(self.client.windows.count)")
    status = "Focusing: \(label(window))…"
    updateStatus()
    client.focus(id: id, fromOverview: fromOverview) { [weak self] result in
      guard let self else { return }
      self.pendingFocusID = nil
      switch result {
      case .success(let focused):
        self.logger.info("focus result=success pid=\(focused.pid) number=\(self.registrationNumbers[id] ?? 0) windows=\(self.client.windows.count)")
        self.selectedID = focused.id
        self.status = "Focused: \(self.label(focused))"
      case .failure(let error):
        self.logger.error("focus result=failure pid=\(window.pid) number=\(self.registrationNumbers[id] ?? 0) reason=\(error.localizedDescription, privacy: .public) windows=\(self.client.windows.count)")
        self.status = error.localizedDescription
      }
      self.updateStatus()
    }
  }

  private func requirePermission() -> Bool {
    guard !terminating else { return false }
    checkPermission()
    guard trusted else {
      logger.error("command rejected reason=accessibility_denied windows=\(self.client.windows.count)")
      status = "Allow InfiniteDesk in Privacy & Security → Accessibility."
      updateStatus()
      return false
    }
    return true
  }

  private func moveToNewPage() {
    guard requirePermission() else { return }
    cycleCursorID = nil
    status = "Moving the focused registered window one page right…"
    updateStatus()
    client.moveFocusedToNewPage { [weak self] result in
      self?.cameraCommandCompleted(result, success: "Moved the focused window and followed it.")
    }
  }

  private func changePage(by direction: Int) {
    guard requirePermission() else { return }
    cycleCursorID = nil
    status = "Switching workspace page…"
    updateStatus()
    client.moveCamera(by: direction) { [weak self] result in
      self?.cameraCommandCompleted(result, success: "Workspace page changed.")
    }
  }

  private func pan(_ packet: DesktopPanPacket) {
    guard trusted, !terminating, !client.camera.paused, client.camera.recoveryCount == 0 else { return }
    cycleCursorID = nil
    client.panCamera(by: packet.delta, ended: packet.ended) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        if packet.ended { self.status = "Workspace panned. Ordinary typing and scrolling stay in the active app." }
      case .failure(.cameraInputCoalesced): return
      case .failure(let error): self.status = error.localizedDescription
      }
      self.updateStatus()
    }
  }

  private func togglePause() {
    guard !terminating else { return }
    if client.camera.paused, client.camera.recoveryCount > 0, !client.camera.requiresRestoration {
      recoverInterruptedSession()
      return
    }
    guard requirePermission() else { return }
    let pause = client.isCameraBusy || !client.camera.paused || client.camera.requiresRestoration
    cycleCursorID = nil
    status = pause ? "Restoring managed windows and pausing…" : "Resuming workspace…"
    updateStatus()
    client.setCameraPaused(pause) { [weak self] result in
      self?.cameraCommandCompleted(result,
        success: pause ? "Paused. Managed windows restored." : "Workspace resumed.")
    }
  }

  private func cameraCommandCompleted(
    _ result: Result<DesktopCameraSnapshot, DesktopWindowError>, success: String
  ) {
    switch result {
    case .success: status = success
    case .failure(let error): status = error.localizedDescription
    }
    updateStatus()
  }

  private func logCommand(_ command: String, source: String) {
    logger.info("command received command=\(command, privacy: .public) source=\(source, privacy: .public) windows=\(self.client.windows.count)")
  }

  private func label(_ window: DesktopWindow) -> String {
    let number = registrationNumbers[window.id] ?? 0
    let frame = window.worldFrame
    let geometry = String(format: "%.0f, %.0f · %.0f×%.0f", frame.minX, frame.minY, frame.width, frame.height)
    let availability: String
    switch window.availability {
    case .available: availability = ""
    case .unavailable: availability = " · unavailable (last known bounds)"
    case .closed: availability = " · closed (last known bounds)"
    }
    let placement = " · page \(window.cameraPage)" + (window.managerMinimized ? " · parked (minimized)" : "")
    return "\(number). \(window.appName) — \(window.title.isEmpty ? "Untitled window" : window.title) · \(geometry)\(placement)\(availability)"
  }

  private func updateStatus() {
    let camera = client.camera
    let mode = camera.paused ? "paused" : "page \(camera.page)"
    statusItem?.button?.toolTip = "InfiniteDesk · \(mode) — \(status)"
  }

  private func rebuildMenu() {
    menu.removeAllItems()
    append("InfiniteDesk · \(client.windows.count) registered", enabled: false)
    append(trusted ? "Accessibility: enabled" : "Accessibility: permission required", enabled: false)
    let camera = client.camera
    let cameraGeometry = String(format: "%.0f, %.0f", camera.origin.x, camera.origin.y)
    let requiresRestoration = camera.requiresRestoration
    append(camera.paused ? (camera.recoveryCount > 0 ? "Workspace: paused · interrupted session needs recovery"
      : requiresRestoration ? "Workspace: paused · managed windows need restoration"
      : "Workspace: paused · managed windows released")
      : "Workspace page \(camera.page) · camera \(cameraGeometry) pt · 1:1", enabled: false)
    if let detail = camera.detail { append(detail, enabled: false).toolTip = detail }
    if camera.recoveryCount > 0 {
      append("Recovery required: \(camera.recoveryCount) interrupted window records", enabled: false)
      append("Recover interrupted session…", action: #selector(recoverInterruptedSession),
        enabled: !terminating && !client.isCameraBusy)
    }
    if client.isCameraBusy { append("Workspace operation in progress…", enabled: false) }
    if let observationStatus = client.observationStatus {
      let observationItem = append(observationStatus, enabled: false)
      observationItem.toolTip = observationStatus
    }
    let messageItem = append(status, enabled: false)
    messageItem.toolTip = status
    if let shortcutWarning {
      let warning = append(shortcutWarning, enabled: false)
      warning.toolTip = shortcutWarning
    }
    if let panWarning {
      let warning = append(panWarning, enabled: false)
      warning.toolTip = panWarning
    }
    menu.addItem(.separator())
    let available = trusted && !terminating && !client.isCameraBusy
    let workspaceAvailable = available && camera.recoveryCount == 0
    append("Register focused window", action: #selector(registerFromMenu), enabled: available,
      shortcut: .register)
    append("Previous window", action: #selector(previousFromMenu), enabled: available && !client.windows.isEmpty,
      shortcut: .previous)
    append("Next window", action: #selector(nextFromMenu), enabled: available && !client.windows.isEmpty,
      shortcut: .next)
    menu.addItem(.separator())
    append("Move focused window one page right and follow", action: #selector(moveToNewPageFromMenu),
      enabled: workspaceAvailable && !camera.paused && client.focusedID != nil, shortcut: .moveToNewPage)
    append("Previous workspace page", action: #selector(previousPageFromMenu),
      enabled: workspaceAvailable && !camera.paused, shortcut: .previousPage)
    append("Next workspace page", action: #selector(nextPageFromMenu),
      enabled: workspaceAvailable && !camera.paused, shortcut: .nextPage)
    append("Pan: hold ⌥⌘ and drag left/right", enabled: false)
    append("Workspace overview", action: #selector(toggleOverview),
      enabled: workspaceAvailable && !camera.paused && !client.windows.isEmpty, shortcut: .overview)
    append("Mouse / trackpad: hold ⌃⌥⌘ and scroll", enabled: false)
    let pauseTitle = camera.paused ? (requiresRestoration ? "Restore managed windows" : "Resume workspace")
      : "Pause and restore windows"
    append(pauseTitle, action: #selector(pauseFromMenu),
      enabled: trusted && !terminating && (requiresRestoration || camera.recoveryCount == 0), shortcut: .pause)
    menu.addItem(.separator())
    if client.windows.isEmpty {
      append("No registered windows", enabled: false)
    } else {
      for window in client.windows {
        let item = append(label(window), action: #selector(selectFromMenu(_:)), enabled: available && window.availability != .closed)
        item.representedObject = window.id.uuidString
        item.state = client.focusedID == window.id ? .on : .off
        item.toolTip = "PID \(window.pid) · Workspace bounds: \(window.worldFrame)"
          + (window.observationDetail.map { " · \($0)" } ?? "")
      }
      let forgetItem = append("Forget registered window")
      let forgetMenu = NSMenu(title: "Forget registered window")
      forgetMenu.autoenablesItems = false
      for window in client.windows {
        let item = NSMenuItem(title: label(window), action: #selector(forgetFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = available
        item.representedObject = window.id.uuidString
        forgetMenu.addItem(item)
      }
      forgetItem.submenu = forgetMenu
    }
    menu.addItem(.separator())
    append("Request Accessibility permission…", action: #selector(requestPermission), enabled: !trusted)
    append("Open Accessibility settings…", action: #selector(openAccessibility))
    append("Retry global input", action: #selector(retryShortcuts))
    menu.addItem(.separator())
    append("Restore windows and quit InfiniteDesk", action: #selector(quit), enabled: !terminating)
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
  @objc private func moveToNewPageFromMenu() {
    logCommand("move-to-new-page", source: "menu")
    moveToNewPage()
  }
  @objc private func previousPageFromMenu() {
    logCommand("previous-page", source: "menu")
    changePage(by: -1)
  }
  @objc private func nextPageFromMenu() {
    logCommand("next-page", source: "menu")
    changePage(by: 1)
  }
  @objc private func pauseFromMenu() {
    logCommand("pause-restore", source: "menu")
    togglePause()
  }
  @objc private func recoverInterruptedSession() {
    guard !terminating, !client.isCameraBusy, client.camera.recoveryCount > 0 else { return }
    let alert = NSAlert()
    alert.messageText = "Restore the interrupted session manually"
    alert.informativeText = "Use each application's Window menu or Dock icon to restore minimized windows, "
      + "then move and resize them to the saved original bounds below. "
      + "InfiniteDesk cannot safely identify these exact windows after restarting. "
      + "Acknowledge only after restoring them or confirming that they closed."
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 260))
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    let text = NSTextView(frame: scroll.bounds)
    text.isEditable = false
    text.isSelectable = true
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.textContainer?.widthTracksTextView = true
    text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
    text.textContainerInset = NSSize(width: 8, height: 8)
    text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    text.string = client.recoveryInstructions
    text.autoresizingMask = [.width]
    scroll.documentView = text
    alert.accessoryView = scroll
    alert.addButton(withTitle: "Keep recovery records")
    let acknowledge = alert.addButton(withTitle: "I restored these windows manually")
    acknowledge.keyEquivalent = ""
    guard alert.runModal() == .alertSecondButtonReturn else { return }
    client.acknowledgeManualRecovery { [weak self] result in
      self?.cameraCommandCompleted(result, success: "Manual recovery acknowledged. Workspace controls are available.")
    }
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
    pendingFocusID = nil
    if selectedID == id { selectedID = nil }
    registrationNumbers.removeValue(forKey: id)
    status = "Forgot: \(removedLabel)"
    updateStatus()
  }
  @objc private func requestPermission() {
    DesktopWindowClient.requestAccessibility()
    checkPermission()
  }
  @objc private func openAccessibility() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
    if !NSWorkspace.shared.open(url) {
      status = "Open System Settings → Privacy & Security → Accessibility."
      updateStatus()
    }
  }
  @objc private func retryShortcuts() {
    checkPermission()
    shortcutWarning = hotkeys?.start()
    panInput?.start()
    updateStatus()
  }
  @objc private func quit() { NSApp.terminate(nil) }
}
