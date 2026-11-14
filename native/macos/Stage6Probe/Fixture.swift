import AppKit

final class FixtureView: NSView {
  let counter = NSTextField(labelWithString: "Clicks: 0  Drags: 0  Keys: 0")
  let downStatus = NSTextField(wrappingLabelWithString: "Down: none")
  let upStatus = NSTextField(wrappingLabelWithString: "Up: none")
  var observedMouseEvents: UInt64 = 0
  var clicks = 0, drags = 0, keys = 0
  override var acceptsFirstResponder: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
    NSColor.gridColor.setStroke()
    let path = NSBezierPath()
    for x in stride(from: 0, through: Int(bounds.width), by: 40) {
      path.move(to: NSPoint(x: x, y: 0))
      path.line(to: NSPoint(x: x, y: Int(bounds.height)))
    }
    for y in stride(from: 0, through: Int(bounds.height), by: 40) {
      path.move(to: NSPoint(x: 0, y: y))
      path.line(to: NSPoint(x: Int(bounds.width), y: y))
    }
    path.stroke()
  }
  func update() { counter.stringValue = "Clicks: \(clicks)  Drags: \(drags)  Keys: \(keys)" }
  override func mouseDown(with event: NSEvent) {
    clicks += 1
    update()
    window?.makeFirstResponder(self)
  }
  override func mouseDragged(with event: NSEvent) {
    drags += 1
    update()
  }
  override func keyDown(with event: NSEvent) {
    keys += 1
    update()
  }
}
@MainActor final class FixtureDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  var child: NSWindow?
  var mouseMonitor: Any?
  var focusTimer: Timer?
  weak var focusText: NSTextView?
  let focusStatus = NSTextField(labelWithString: "Focus unavailable")
  func applicationDidFinishLaunching(_ notification: Notification) {
    window = NSWindow(
      contentRect: NSRect(x: 160, y: 180, width: 640, height: 480),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = "InfiniteDesk Stage 6 Fixture"
    window.isReleasedWhenClosed = false
    window.setAccessibilityIdentifier(fixtureAXMainID)
    let view = FixtureView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    view.autoresizingMask = [.width, .height]
    view.counter.frame = NSRect(x: 20, y: 20, width: 500, height: 24)
    view.counter.autoresizingMask = [.maxYMargin]
    view.addSubview(view.counter)
    view.downStatus.frame = NSRect(x: 20, y: 45, width: 610, height: 36)
    view.upStatus.frame = NSRect(x: 20, y: 80, width: 610, height: 36)
    for label in [view.downStatus, view.upStatus] {
      label.autoresizingMask = [.maxYMargin]
      view.addSubview(label)
    }
    mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .leftMouseUp, .leftMouseDragged,
    ]) { [weak self, weak view] event in
      // AppKit documents that local event monitor handlers run on the main thread.
      MainActor.assumeIsolated {
        guard let self, let view else { return }
        guard event.type == .leftMouseDown || event.type == .leftMouseUp else { return }
        view.observedMouseEvents &+= 1
        let isDown = event.type == .leftMouseDown
        let sameWindow = event.window === self.window
        let hit: String
        if isDown, sameWindow, let parent = view.superview {
          let parentPoint = parent.convert(event.locationInWindow, from: nil)
          if let target = view.hitTest(parentPoint) {
            hit = "\(type(of: target)) firstMouse=\(target.acceptsFirstMouse(for: event))"
          } else {
            hit = "none"
          }
        } else {
          hit = "not checked"
        }
        let global = event.cgEvent.map { String(describing: $0.location) } ?? "unavailable"
        let status =
          "#\(view.observedMouseEvents) window=\(event.windowNumber) same=\(sameWindow) local=\(event.locationInWindow) CG=\(global)\nnumber=\(event.eventNumber) hit=\(hit) active=\(NSApp.isActive) key=\(self.window.isKeyWindow)"
        if isDown {
          view.downStatus.stringValue = "Down " + status
        } else {
          view.upStatus.stringValue = "Up " + status
        }
      }
      return event
    }
    focusStatus.frame = NSRect(x: 20, y: 118, width: 610, height: 18)
    focusStatus.autoresizingMask = [.maxYMargin]
    view.addSubview(focusStatus)
    let scroll = NSScrollView(frame: NSRect(x: 20, y: 140, width: 400, height: 200))
    scroll.hasVerticalScroller = true
    let text = NSTextView(frame: scroll.bounds)
    text.string = "Synthetic fixture: edit this text.\n"
    scroll.documentView = text
    focusText = text
    view.addSubview(scroll)
    let sheet = NSButton(title: "Sheet", target: self, action: #selector(showSheet))
    sheet.frame = NSRect(x: 440, y: 250, width: 120, height: 32)
    view.addSubview(sheet)
    let childButton = NSButton(title: "Child window", target: self, action: #selector(showChild))
    childButton.frame = NSRect(x: 440, y: 210, width: 120, height: 32)
    view.addSubview(childButton)
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    updateFocusStatus()
    focusTimer = Timer.scheduledTimer(
      timeInterval: 0.25, target: self, selector: #selector(updateFocusStatus), userInfo: nil,
      repeats: true)
    let identity =
      "fixture pid=\(ProcessInfo.processInfo.processIdentifier) window=\(window.windowNumber)\n"
    FileHandle.standardOutput.write(Data(identity.utf8))
  }
  @objc func updateFocusStatus() {
    guard let text = focusText else { return }
    let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
    let status =
      "Fixture active=\(NSApp.isActive) key=\(window.isKeyWindow) responder=\(responder) text=\(window.firstResponder === text) selection=\(text.selectedRange())"
    if focusStatus.stringValue != status { focusStatus.stringValue = status }
  }
  @objc func showSheet() {
    let alert = NSAlert()
    alert.messageText = "Synthetic sheet"
    alert.addButton(withTitle: "Close")
    alert.beginSheetModal(for: window)
  }
  @objc func showChild() {
    guard child == nil else {
      child?.close()
      child = nil
      return
    }
    let w = NSWindow(
      contentRect: NSRect(x: 260, y: 280, width: 240, height: 120),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.setAccessibilityIdentifier(fixtureAXChildID)
    w.title = "Synthetic child"
    w.contentView?.addSubview(NSTextField(labelWithString: "Fixture child"))
    window.addChildWindow(w, ordered: .above)
    w.orderFront(nil)
    child = w
  }
  func applicationWillTerminate(_ notification: Notification) {
    focusTimer?.invalidate()
    if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(
  withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
mainMenu.addItem(appMenuItem)
app.mainMenu = mainMenu
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
