import AppKit
import Foundation
import WebKit

private let homeAddress = "https://www.wikipedia.org/"

func browserVisibleGeometry(
  x: Double, y: Double, width: Double, height: Double, zoom: Double,
  viewportWidth: Double, viewportHeight: Double
) -> (frame: CGRect, bounds: CGRect)? {
  guard [x, y, width, height, zoom, viewportWidth, viewportHeight].allSatisfy(\.isFinite),
    width > 0, height > 0, zoom > 0, viewportWidth > 0, viewportHeight > 0
  else { return nil }
  let displayWidth = width * zoom
  let displayHeight = height * zoom
  guard displayWidth.isFinite, displayHeight.isFinite else { return nil }
  let viewport = CGRect(x: 0, y: 0, width: viewportWidth, height: viewportHeight)
  let visible = CGRect(x: x, y: y, width: displayWidth, height: displayHeight).intersection(
    viewport)
  guard !visible.isNull, !visible.isEmpty else { return nil }
  let bounds = CGRect(
    x: (visible.minX - x) / zoom, y: (visible.minY - y) / zoom,
    width: visible.width / zoom, height: visible.height / zoom)
  guard [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite),
    bounds.width > 0, bounds.height > 0
  else { return nil }
  return (visible, bounds)
}

func browserRectArea(_ rect: CGRect) -> CGFloat {
  rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
}

func browserUncoveredRectangles(_ rectangle: CGRect, occluders: [CGRect]) -> [CGRect] {
  guard !rectangle.isNull, !rectangle.isEmpty else { return [] }
  return occluders.reduce([rectangle]) { remaining, blocker in
    remaining.flatMap { rect -> [CGRect] in
      let overlap = rect.intersection(blocker)
      guard !overlap.isNull, !overlap.isEmpty else { return [rect] }
      return [
        CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
        CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
        CGRect(
          x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
        CGRect(
          x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height),
      ].filter { !$0.isEmpty }
    }
  }
}

func browserLargestNativeFrame(candidates: [CGRect], displays: [CGRect]) -> CGRect? {
  candidates.flatMap { candidate in
    displays.map { candidate.intersection($0) }.filter {
      !$0.isNull && $0.width >= 320 && $0.height >= 240
    }
  }.max { browserRectArea($0) < browserRectArea($1) }
}

func browserNativeApplicationLabels(_ applications: [NativeWindowApplication]) -> [String] {
  let counts = Dictionary(grouping: applications, by: \.appName).mapValues(\.count)
  return applications.map {
    $0.appName + (counts[$0.appName, default: 0] > 1 ? " · PID \($0.id)" : "")
      + ($0.suggested ? " · recent" : "")
  }
}

func browserNativeWindowLabels(_ choices: [NativeWindowChoice]) -> [String] {
  let titles = choices.map { $0.title.isEmpty ? "Untitled window" : $0.title }
  let counts = Dictionary(grouping: titles, by: { $0 }).mapValues(\.count)
  let labels = zip(choices, titles).map { choice, title in
    guard counts[title, default: 0] > 1 else { return title }
    let frame = choice.frame
    return title + " · "
      + String(
        format: "%.0f,%.0f · %.0f×%.0f",
        frame.minX, frame.minY, frame.width, frame.height)
  }
  let labelCounts = Dictionary(grouping: labels, by: { $0 }).mapValues(\.count)
  return labels.enumerated().map { index, label in
    label + (labelCounts[label, default: 0] > 1 ? " · #\(index + 1)" : "")
  }
}

private struct NativeApplicationSelection {
  let application: NativeWindowApplication
  let generation: UInt64
}

private struct NativeWindowSelection {
  let choice: NativeWindowChoice
  let generation: UInt64
}

@MainActor private final class BrowserClip: NSView {
  var occluders: [CGRect] = []
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard bounds.contains(local), !occluders.contains(where: { $0.contains(local) }),
      let child = subviews.first, child.frame.contains(local)
    else {
      return nil
    }
    return super.hitTest(point)
  }
}

@MainActor private final class BrowserSurface: NSView {
  override var isFlipped: Bool { true }
}

@MainActor private final class PreviewView: NSView {
  var usesTopLeftOrigin = false
  override var isFlipped: Bool { usesTopLeftOrigin }
  var onClick: ((CGPoint) -> Void)?
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    guard usesTopLeftOrigin, let hit, !(hit is NSButton) else { return hit }
    return self
  }
  var pickingField = false {
    didSet { window?.invalidateCursorRects(for: self) }
  }
  override func resetCursorRects() {
    super.resetCursorRects()
    if pickingField { addCursorRect(visibleRect, cursor: .crosshair) }
  }
  override var acceptsFirstResponder: Bool { true }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    onClick?(convert(event.locationInWindow, from: nil))
  }
}

@MainActor
private final class Browser: NSObject, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
  let parent: NSView
  let mask = CAShapeLayer()
  let clip = BrowserClip()
  let surface = BrowserSurface()
  var webView: WKWebView?
  let address = NSTextField()
  let back = NSButton(title: "‹", target: nil, action: nil)
  let forward = NSButton(title: "›", target: nil, action: nil)
  let home = NSButton(title: "⌂", target: nil, action: nil)
  let status = NSTextField(labelWithString: "")
  let capture = WindowCapture()
  let preview = PreviewView()
  let chooseWindow = NSButton(title: "Window…", target: nil, action: nil)
  let choosePreview = NSButton(title: "Preview…", target: nil, action: nil)
  let useRealWindow = NSButton(title: "Use real window…", target: nil, action: nil)
  let workInWindow = NSButton(title: "Work in window", target: nil, action: nil)
  let restoreWindow = NSButton(title: "Restore", target: nil, action: nil)
  let nativeSurface = PreviewView()
  let nativeTitle = NSTextField(labelWithString: "Work in the original macOS window")
  let nativeHelp = NSTextField(
    wrappingLabelWithString:
      "Choose an app and window. InfiniteDesk places the original here; typing and shortcuts stay native.\n\nReturn: click exposed canvas or title, or use Cmd+Tab. Resume: click this card or press Cmd+Return. Restore returns the original size and position."
  )
  let nativeClient = NativeWindowClient()
  var nativeChoice: NativeWindowChoice?
  var nativeBusy = false
  var nativeChooserGeneration: UInt64 = 0
  var destroyed = false
  var nativeContextObserver: NSObjectProtocol?
  var cardSize = CGSize.zero
  let returnToWeb = NSButton(title: "Web", target: nil, action: nil)
  let openApp = NSButton(title: "Open app", target: nil, action: nil)
  let focusWindow = NSButton(title: "Focus window", target: nil, action: nil)
  let previewTools = NSButton(title: "More…", target: nil, action: nil)
  let textLabel = NSTextField(labelWithString: "")
  let textEditor = NSTextField()
  let textSend = NSButton(title: "Replace", target: nil, action: nil)
  var textTarget: TextTarget?
  let chromeHeight: CGFloat = 44
  var escapeMonitor: Any?
  var selected = false

  init(parent: NSView, id: UInt64, startWeb: Bool) {
    self.parent = parent
    super.init()
    nativeContextObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.nativeChooserGeneration &+= 1 }
    }
    clip.setAccessibilityIdentifier("infinitedesk.card.\(id)")
    clip.wantsLayer = true
    clip.layer?.masksToBounds = true
    clip.layer?.mask = mask
    clip.addSubview(surface)
    surface.wantsLayer = true
    surface.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    back.target = self
    back.action = #selector(goBack)
    forward.target = self
    forward.action = #selector(goForward)
    home.target = self
    home.action = #selector(goHome)
    back.setAccessibilityLabel("Back")
    forward.setAccessibilityLabel("Forward")
    home.setAccessibilityLabel("Home")
    address.setAccessibilityLabel("Web address")
    address.placeholderString = homeAddress
    address.target = self
    address.action = #selector(navigate)
    address.delegate = self
    chooseWindow.target = self
    chooseWindow.action = #selector(selectWindow)
    choosePreview.target = self
    choosePreview.action = #selector(selectPreview)
    choosePreview.setAccessibilityHelp("Share a live preview of a window")
    useRealWindow.target = self
    useRealWindow.action = #selector(selectWindow)
    workInWindow.target = self
    workInWindow.action = #selector(workInSourceWindow)
    workInWindow.setAccessibilityHelp(
      "Place and activate the original window. Shortcut: Command Return")
    restoreWindow.target = self
    restoreWindow.action = #selector(restoreSourceWindow)
    restoreWindow.setAccessibilityHelp("Restore the original window's previous size and position")
    workInWindow.isHidden = true
    restoreWindow.isHidden = true
    nativeSurface.usesTopLeftOrigin = true
    nativeTitle.font = .systemFont(ofSize: 19, weight: .semibold)
    nativeHelp.textColor = .secondaryLabelColor
    nativeSurface.onClick = { [weak self] _ in
      guard self?.nativeChoice != nil else { return }
      self?.workInSourceWindow()
    }
    nativeSurface.addSubview(nativeTitle)
    nativeSurface.addSubview(nativeHelp)
    nativeSurface.addSubview(useRealWindow)
    returnToWeb.target = self
    returnToWeb.action = #selector(showWeb)
    openApp.target = self
    openApp.action = #selector(openSourceApplication)
    focusWindow.target = self
    focusWindow.action = #selector(focusSourceWindow)
    previewTools.target = self
    previewTools.action = #selector(showPreviewTools)
    previewTools.isHidden = true
    textSend.target = self
    textSend.action = #selector(sendTextValue)
    textEditor.placeholderString = "Replacement text"
    textEditor.setAccessibilityLabel("Replacement text for the selected Chrome field")
    textEditor.setAccessibilityHelp("Replace writes the entire field value. Escape cancels.")
    textSend.setAccessibilityHelp("Replace the entire value in the identified Chrome field")
    textLabel.isHidden = true
    textEditor.isHidden = true
    textSend.isHidden = true
    preview.onClick = { [weak self] point in
      guard let self else { return }
      if self.preview.pickingField {
        self.pickTextField(at: point)
      } else {
        self.focusSourceWindow()
      }
    }
    preview.wantsLayer = true
    preview.layer?.addSublayer(capture.layer)
    preview.isHidden = true
    returnToWeb.isHidden = true
    openApp.isHidden = true
    focusWindow.isHidden = true
    capture.onInvalidate = { [weak self] in
      guard let self else { return }
      self.closeTextMode()
      self.status.stringValue =
        "Capture changed or became unavailable; choose a field after the preview resumes."
      self.status.isHidden = false
    }
    capture.onUpdate = { [weak self] message, started in
      guard let self else { return }
      self.status.stringValue = message
      self.status.isHidden = false
      self.openApp.isEnabled = self.capture.canOpenApplication
      self.focusWindow.isEnabled = self.capture.canFocusWindow
      self.previewTools.isHidden = !self.capture.canFocusWindow || self.capture.textTarget == nil
      self.closeTextMode()
      if started {
        self.nativeSurface.isHidden = true
        self.webView?.isHidden = true
        self.preview.isHidden = false
        self.back.isHidden = true
        self.forward.isHidden = true
        self.home.isHidden = true
        self.address.isHidden = true
        self.returnToWeb.isHidden = false
        self.openApp.isHidden = !self.capture.canOpenApplication
        self.focusWindow.isHidden = !self.capture.canFocusWindow
      }
    }
    surface.addSubview(back)
    surface.addSubview(forward)
    surface.addSubview(home)
    surface.addSubview(address)
    surface.addSubview(preview)
    surface.addSubview(chooseWindow)
    surface.addSubview(choosePreview)
    surface.addSubview(nativeSurface)
    surface.addSubview(workInWindow)
    surface.addSubview(restoreWindow)
    surface.addSubview(returnToWeb)
    surface.addSubview(openApp)
    surface.addSubview(focusWindow)
    surface.addSubview(status)
    surface.addSubview(previewTools)
    surface.addSubview(textLabel)
    surface.addSubview(textEditor)
    surface.addSubview(textSend)
    parent.addSubview(clip)
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let handled = MainActor.assumeIsolated {
        guard let self, let window = self.parent.window, event.window === window else {
          return false
        }
        if routeFocusShortcut(
          keyCode: event.keyCode, modifiers: event.modifierFlags,
          isRepeat: event.isARepeat,
          selected: self.selected && (self.nativeChoice != nil || !self.preview.isHidden),
          focus: {
            if self.nativeChoice != nil {
              self.workInSourceWindow()
            } else {
              self.focusSourceWindow()
            }
          })
        {
          return true
        }
        let plainEscape =
          event.keyCode == 53
          && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if plainEscape && self.selected
          && (self.preview.pickingField || self.textTarget != nil || self.capture.textGate != nil)
        {
          self.closeTextMode()
          self.status.stringValue = "Text editing cancelled."
          self.status.isHidden = false
          return true
        }
        guard let responder = window.firstResponder else { return false }
        let inBrowser =
          (responder as? NSView)?.isDescendant(of: self.clip) == true
          || self.address.currentEditor() === responder
        guard inBrowser else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 && modifiers.isEmpty {
          window.makeFirstResponder(self.parent)
          return true
        }
        return false
      }
      return handled ? nil : event
    }
    if startWeb {
      showWeb()
    } else {
      back.isHidden = true
      forward.isHidden = true
      home.isHidden = true
      address.isHidden = true
      returnToWeb.isHidden = false
      status.stringValue = "Window… uses Accessibility. Preview… is optional screen sharing."
    }
  }

  func setFrame(
    x: Double, y: Double, width: Double, height: Double, zoom: Double,
    viewportWidth: Double, viewportHeight: Double
  ) {
    guard height > chromeHeight,
      let geometry = browserVisibleGeometry(
        x: x, y: y, width: width, height: height, zoom: zoom,
        viewportWidth: viewportWidth, viewportHeight: viewportHeight)
    else {
      clip.isHidden = true
      return
    }
    cardSize = CGSize(width: width, height: height)
    let parentBounds = parent.bounds
    let clipY = parent.isFlipped ? parentBounds.minY : parentBounds.maxY - viewportHeight
    let clipFrame = NSRect(
      x: parentBounds.minX, y: clipY, width: viewportWidth, height: viewportHeight)
    let viewport = NSRect(x: 0, y: 0, width: viewportWidth, height: viewportHeight)
    clip.isHidden = false
    if clip.frame != clipFrame { clip.frame = clipFrame }
    if clip.bounds != viewport { clip.bounds = viewport }
    updateMask()
    if surface.frame != geometry.frame { surface.frame = geometry.frame }
    if surface.bounds != geometry.bounds { surface.bounds = geometry.bounds }
    func setFrame(_ view: NSView, _ frame: NSRect) {
      if view.frame != frame { view.frame = frame }
    }
    setFrame(back, NSRect(x: 6, y: 7, width: 30, height: 30))
    setFrame(forward, NSRect(x: 38, y: 7, width: 30, height: 30))
    setFrame(home, NSRect(x: 70, y: 7, width: 30, height: 30))
    setFrame(address, NSRect(x: 106, y: 9, width: max(1, width - 322), height: 25))
    setFrame(chooseWindow, NSRect(x: width - 204, y: 7, width: 96, height: 30))
    setFrame(choosePreview, NSRect(x: width - 104, y: 7, width: 98, height: 30))
    setFrame(workInWindow, NSRect(x: 80, y: 7, width: 128, height: 30))
    setFrame(restoreWindow, NSRect(x: 212, y: 7, width: 76, height: 30))
    setFrame(
      nativeSurface, NSRect(x: 0, y: chromeHeight, width: width, height: height - chromeHeight))
    setFrame(nativeTitle, NSRect(x: 24, y: 30, width: max(1, width - 48), height: 28))
    setFrame(nativeHelp, NSRect(x: 24, y: 72, width: max(1, width - 48), height: 138))
    setFrame(useRealWindow, NSRect(x: 20, y: 224, width: 174, height: 36))
    setFrame(returnToWeb, NSRect(x: 6, y: 7, width: 70, height: 30))
    setFrame(focusWindow, NSRect(x: 80, y: 7, width: 110, height: 30))
    setFrame(openApp, NSRect(x: 194, y: 7, width: 82, height: 30))
    setFrame(previewTools, NSRect(x: 280, y: 7, width: 64, height: 30))
    setFrame(textLabel, NSRect(x: 8, y: chromeHeight + 6, width: max(1, width - 16), height: 18))
    setFrame(textEditor, NSRect(x: 8, y: chromeHeight + 28, width: max(1, width - 90), height: 25))
    setFrame(textSend, NSRect(x: width - 78, y: chromeHeight + 26, width: 70, height: 30))
    if let webView {
      setFrame(webView, NSRect(x: 0, y: chromeHeight, width: width, height: height - chromeHeight))
    }
    setFrame(preview, NSRect(x: 0, y: chromeHeight, width: width, height: height - chromeHeight))
    capture.layer.frame = preview.bounds
    setFrame(status, NSRect(x: 8, y: height - 24, width: max(1, width - 16), height: 18))
    status.isHidden = status.stringValue.isEmpty
  }

  func setOccluders(_ rectangles: [CGRect]) {
    clip.occluders = rectangles.filter {
      [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite)
        && $0.width > 0 && $0.height > 0
    }
    updateMask()
  }

  func updateMask() {
    let remaining = browserUncoveredRectangles(clip.bounds, occluders: clip.occluders)
    let path = CGMutablePath()
    for rect in remaining { path.addRect(clip.convertToLayer(rect)) }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    mask.frame = clip.layer?.bounds ?? .zero
    mask.path = path
    CATransaction.commit()
  }

  func closeTextMode(reason: String? = nil) {
    let hadTextSession = preview.pickingField || textTarget != nil || capture.textGate != nil
    capture.textGate?.cancel()
    capture.textGate = nil
    preview.pickingField = false
    if let editor = textEditor.currentEditor(), parent.window?.firstResponder === editor {
      parent.window?.makeFirstResponder(parent)
    }
    textTarget = nil
    textEditor.stringValue = ""
    textLabel.isHidden = true
    textEditor.isHidden = true
    textSend.isHidden = true
    if hadTextSession, let reason {
      status.stringValue = reason
      status.isHidden = false
    }
  }
  func canChooseTextField() -> Bool {
    guard selected else {
      status.stringValue = "Text operation cancelled: select this card and choose a field again."
      status.isHidden = false
      return false
    }
    guard NSApp.isActive else {
      status.stringValue =
        "Text operation unavailable: activate InfiniteDesk's board window and retry."
      status.isHidden = false
      return false
    }
    guard parent.window?.isKeyWindow == true else {
      status.stringValue =
        "Text operation unavailable: bring this board window to the front and retry."
      status.isHidden = false
      return false
    }
    guard textAccessibilityAvailable() else {
      status.stringValue = "Accessibility access is unavailable for InfiniteDesk."
      status.isHidden = false
      return false
    }
    guard capture.textTarget != nil else {
      status.stringValue = "A live Chrome window capture is required."
      status.isHidden = false
      return false
    }
    return true
  }

  @objc func showPreviewTools() {
    let menu = NSMenu(title: "Preview tools")
    let focused = NSMenuItem(
      title: "Replace focused Chrome field…",
      action: #selector(beginTextMode), keyEquivalent: "")
    focused.target = self
    focused.isEnabled = capture.canFocusWindow && capture.textTarget != nil
    menu.addItem(focused)
    let pick = NSMenuItem(
      title: preview.pickingField ? "Cancel field selection" : "Pick Chrome field…",
      action: #selector(toggleFieldPicking), keyEquivalent: "")
    pick.target = self
    pick.isEnabled = focused.isEnabled
    menu.addItem(pick)
    menu.popUp(
      positioning: nil, at: CGPoint(x: previewTools.frame.minX, y: chromeHeight), in: surface)
  }

  @objc func toggleFieldPicking() {
    if preview.pickingField {
      closeTextMode()
      status.stringValue = "Field selection cancelled."
      return
    }
    guard canChooseTextField() else { return }
    capture.cancelPendingFocus()
    closeTextMode()
    preview.pickingField = true
    parent.window?.makeFirstResponder(preview)
    status.stringValue = "Click an ordinary Chrome page field in the preview. Escape cancels."
    status.isHidden = false
  }

  func pickTextField(at point: CGPoint) {
    guard canChooseTextField() else {
      closeTextMode()
      return
    }
    guard let geometry = capture.displayedGeometry,
      let normalized = geometry.normalizedPoint(
        point, in: preview.bounds, flipped: preview.isFlipped)
    else {
      closeTextMode()
      status.stringValue =
        "Click inside the captured window after choosing More… → Pick Chrome field…."
      status.isHidden = false
      return
    }
    inspectField(point: normalized, sourceSize: geometry.sourceSize)
  }

  @objc func beginTextMode() {
    guard canChooseTextField() else { return }
    inspectField()
  }

  func inspectField(point: CGPoint? = nil, sourceSize: CGSize? = nil) {
    guard let (identity, app) = capture.textTarget else {
      closeTextMode()
      status.stringValue = "Field selection cancelled: the Chrome capture is no longer available."
      status.isHidden = false
      return
    }
    capture.cancelPendingFocus()
    closeTextMode()
    let gate = WindowTextGate()
    capture.textGate = gate
    status.stringValue =
      point == nil ? "Checking Chrome's focused field…" : "Checking selected Chrome field…"
    status.isHidden = false
    inspectTextTarget(
      identity: identity, app: app, gate: gate, point: point, sourceSize: sourceSize
    ) {
      [weak self] target, failure in
      guard let self, self.capture.textGate === gate else { return }
      guard self.selected else {
        self.closeTextMode(reason: "Field selection cancelled: this card is no longer selected.")
        return
      }
      self.capture.textGate = nil
      guard let target else {
        self.status.stringValue = failure ?? "No supported editable Chrome page field was found."
        return
      }
      self.textTarget = target
      self.textLabel.stringValue = "Replace entire value in: \(target.title)"
      self.textLabel.isHidden = false
      self.textEditor.isHidden = false
      self.textSend.isHidden = false
      self.status.stringValue = "Text replaces the whole field."
      self.parent.window?.makeFirstResponder(self.textEditor)
    }
  }
  @objc func sendTextValue() {
    guard canChooseTextField() else {
      closeTextMode()
      return
    }
    guard let expected = textTarget else {
      closeTextMode()
      status.stringValue = "Replacement not sent: choose the Chrome field again."
      status.isHidden = false
      return
    }
    guard let (identity, app) = capture.textTarget else {
      closeTextMode()
      status.stringValue = "Replacement not sent: the Chrome capture is no longer available."
      status.isHidden = false
      return
    }
    let value = textEditor.stringValue
    guard !value.isEmpty else {
      status.stringValue = "Enter replacement text; empty values are not sent."
      status.isHidden = false
      return
    }
    capture.cancelPendingFocus()
    let gate = WindowTextGate()
    closeTextMode()
    capture.textGate = gate
    status.stringValue = "Replacing the selected Chrome field…"
    status.isHidden = false
    sendText(identity: identity, app: app, gate: gate, expected: expected, text: value) {
      [weak self] message in
      guard let self, self.capture.textGate === gate else { return }
      self.capture.textGate = nil
      self.status.stringValue = message
      self.status.isHidden = false
    }
  }
  func nativeStatus(_ message: String) {
    status.stringValue = message
    status.isHidden = false
  }

  func nativeChooserIsCurrent(_ generation: UInt64) -> Bool {
    !destroyed && nativeChooserGeneration == generation && !clip.isHidden
      && NSApp.isActive && parent.window?.isKeyWindow == true
  }

  @objc func selectWindow() {
    guard !nativeBusy, !destroyed else { return }
    nativeChooserGeneration &+= 1
    let generation = nativeChooserGeneration
    closeTextMode()
    let menu = NSMenu(title: "Use a real window")
    let applications = nativeClient.applications()
    for (application, title) in zip(applications, browserNativeApplicationLabels(applications)) {
      let item = NSMenuItem(
        title: title,
        action: #selector(selectNativeApplication(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = NativeApplicationSelection(
        application: application, generation: generation)
      menu.addItem(item)
    }
    if menu.items.isEmpty {
      nativeStatus("Open another application with a normal window, then choose Window….")
      return
    }
    menu.popUp(
      positioning: nil, at: CGPoint(x: chooseWindow.frame.minX, y: chromeHeight), in: surface)
  }

  @objc func selectNativeApplication(_ sender: NSMenuItem) {
    guard let selection = sender.representedObject as? NativeApplicationSelection,
      !nativeBusy, nativeChooserIsCurrent(selection.generation)
    else { return }
    let application = selection.application
    let generation = selection.generation
    nativeBusy = true
    nativeStatus("Reading windows in \(application.appName)…")
    nativeClient.discover(application: application) { [weak self] result in
      guard let self else { return }
      self.nativeBusy = false
      guard self.nativeChooserIsCurrent(generation) else {
        self.nativeStatus("Window selection cancelled. Choose Window… again.")
        return
      }
      switch result {
      case .failure(let error): self.nativeStatus(error.localizedDescription)
      case .success(let choices):
        guard !choices.isEmpty else {
          self.nativeStatus(
            "No movable windows found. Open a normal window in \(application.appName) and retry.")
          return
        }
        let menu = NSMenu(title: application.appName)
        for (choice, title) in zip(choices, browserNativeWindowLabels(choices)) {
          let item = NSMenuItem(
            title: title,
            action: #selector(self.selectNativeChoice(_:)), keyEquivalent: "")
          item.target = self
          item.representedObject = NativeWindowSelection(choice: choice, generation: generation)
          menu.addItem(item)
        }
        self.nativeStatus("Choose the exact window to work in.")
        menu.popUp(
          positioning: nil,
          at: CGPoint(x: self.chooseWindow.frame.minX, y: self.chromeHeight), in: self.surface)
      }
    }
  }

  @objc func selectNativeChoice(_ sender: NSMenuItem) {
    guard let selection = sender.representedObject as? NativeWindowSelection,
      !nativeBusy, nativeChooserIsCurrent(selection.generation)
    else { return }
    let choice = selection.choice
    let generation = selection.generation
    if nativeChoice != nil {
      nativeBusy = true
      nativeClient.restore { [weak self] result in
        guard let self else { return }
        self.nativeBusy = false
        switch result {
        case .failure(let error): self.nativeStatus(error.localizedDescription)
        case .success:
          self.nativeChoice = nil
          self.showNativeSurface()
          guard self.nativeChooserIsCurrent(generation) else {
            self.nativeStatus("Window selection cancelled. Previous window restored.")
            return
          }
          self.nativeChooserGeneration &+= 1
          self.placeNativeWindow(choice)
        }
      }
    } else {
      nativeChooserGeneration &+= 1
      placeNativeWindow(choice)
    }
  }

  func nativeTargetFrame() -> CGRect? {
    guard !clip.isHidden, let window = parent.window, let primary = NSScreen.screens.first else {
      return nil
    }
    let content = CGRect(
      x: 0, y: chromeHeight + 8,
      width: cardSize.width, height: cardSize.height - chromeHeight - 40)
    let inClip = clip.convert(content, from: surface).intersection(surface.frame).intersection(
      clip.bounds)
    let available = browserUncoveredRectangles(inClip, occluders: clip.occluders)
    let candidates = available.map { window.convertToScreen(clip.convert($0, to: nil)) }
    guard
      let visible = browserLargestNativeFrame(
        candidates: candidates,
        displays: NSScreen.screens.map(\.visibleFrame))
    else { return nil }
    return nativeAXFrame(fromAppKit: visible, primaryScreenMaxY: primary.frame.maxY)
  }

  func showNativeSurface() {
    closeTextMode()
    capture.stop()
    webView?.isHidden = true
    preview.isHidden = true
    nativeSurface.isHidden = false
    for view in [
      back, forward, home, address, openApp, focusWindow, previewTools,
    ] {
      view.isHidden = true
    }
    returnToWeb.isHidden = false
    workInWindow.isHidden = nativeChoice == nil
    restoreWindow.isHidden = nativeChoice == nil
    nativeTitle.stringValue =
      nativeChoice.map { "\($0.appName) · \($0.title)" }
      ?? "Work in the original macOS window"
    useRealWindow.title = nativeChoice == nil ? "Use real window…" : "Choose another window…"
  }

  func placeNativeWindow(_ choice: NativeWindowChoice) {
    guard !nativeBusy else { return }
    guard let frame = nativeTargetFrame() else {
      nativeStatus("Enlarge or zoom into this card: a visible 320 × 240 point area is required.")
      return
    }
    nativeChoice = choice
    showNativeSurface()
    nativeBusy = true
    nativeStatus("Placing the original \(choice.appName) window…")
    nativeClient.place(choice: choice, frame: frame) { [weak self] result in
      guard let self else { return }
      self.nativeBusy = false
      switch result {
      case .failure(let error): self.nativeStatus(error.localizedDescription)
      case .success(let placement):
        self.nativeChoice = choice
        self.showNativeSurface()
        self.nativeStatus(
          placement.adjusted
            ? "App adjusted its minimum size. Return via canvas or Cmd+Tab; Restore returns its frame."
            : "Original window active. Return via canvas or Cmd+Tab; resume with Cmd+Return.")
      }
    }
  }

  @objc func workInSourceWindow() {
    guard let nativeChoice else { return }
    placeNativeWindow(nativeChoice)
  }

  @objc func restoreSourceWindow() {
    guard !nativeBusy, nativeChoice != nil else { return }
    nativeBusy = true
    nativeClient.restore { [weak self] result in
      guard let self else { return }
      self.nativeBusy = false
      switch result {
      case .failure(let error): self.nativeStatus(error.localizedDescription)
      case .success:
        self.nativeChoice = nil
        self.showNativeSurface()
        self.nativeStatus("Original window size and position restored.")
      }
    }
  }

  @objc func selectPreview() {
    guard !nativeBusy else { return }
    nativeChooserGeneration &+= 1
    if nativeChoice != nil {
      nativeStatus("Restore the real window before starting an optional preview.")
      return
    }
    closeTextMode(reason: "Text operation cancelled while choosing another captured window.")
    capture.selectWindow()
  }
  @objc func openSourceApplication() {
    closeTextMode(reason: "Text operation cancelled while opening the source application.")
    capture.openApplication()
  }
  @objc func focusSourceWindow() {
    closeTextMode(reason: "Text operation cancelled while focusing the source window.")
    guard capture.canFocusWindow else {
      status.stringValue = "Window focus unavailable; use Open app."
      status.isHidden = false
      return
    }
    capture.focusWindow { [weak self] message in
      self?.status.stringValue = message
      self?.status.isHidden = false
    }
  }
  @objc func showWeb() {
    guard !nativeBusy else { return }
    nativeChooserGeneration &+= 1
    if nativeChoice != nil {
      nativeStatus("Restore the real window before switching this card to Web.")
      return
    }
    nativeSurface.isHidden = true
    previewTools.isHidden = true
    workInWindow.isHidden = true
    restoreWindow.isHidden = true
    closeTextMode()
    capture.stop()
    let isNew = webView == nil
    if isNew {
      let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
      view.navigationDelegate = self
      view.uiDelegate = self
      surface.addSubview(view, positioned: .below, relativeTo: preview)
      webView = view
      view.frame = preview.frame
    }
    webView?.isHidden = false
    preview.isHidden = true
    back.isHidden = false
    forward.isHidden = false
    home.isHidden = false
    address.isHidden = false
    returnToWeb.isHidden = true
    openApp.isHidden = true
    focusWindow.isHidden = true
    status.stringValue = ""
    status.isHidden = true
    updateNavigation()
    if isNew { goHome() }
  }
  @objc func goBack() { if webView?.canGoBack == true { webView?.goBack() } }
  @objc func goForward() { if webView?.canGoForward == true { webView?.goForward() } }
  @objc func goHome() {
    guard let url = URL(string: homeAddress), let webView else { return }
    address.stringValue = homeAddress
    status.stringValue = ""
    status.isHidden = true
    webView.load(URLRequest(url: url))
  }
  @objc func navigate() {
    let raw = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate = raw.contains("://") ? raw : "https://" + raw
    guard let components = URLComponents(string: candidate),
      let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = components.host, !host.isEmpty, let url = components.url
    else {
      status.stringValue = "Enter a valid http or https address."
      status.isHidden = false
      return
    }
    status.stringValue = ""
    status.isHidden = true
    webView?.load(URLRequest(url: url))
  }
  func updateNavigation(updateAddress: Bool = true) {
    back.isEnabled = webView?.canGoBack == true
    forward.isEnabled = webView?.canGoForward == true
    guard updateAddress else { return }
    if let url = webView?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
      address.stringValue = url.absoluteString
    } else {
      address.stringValue = ""
    }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { updateNavigation() }
  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    status.stringValue = ""
    status.isHidden = true
    updateNavigation()
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    let nsError = error as NSError
    guard nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled else { return }
    status.stringValue = "Navigation failed: \(error.localizedDescription)"
    status.isHidden = false
    updateNavigation(updateAddress: false)
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    let nsError = error as NSError
    guard nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled else { return }
    status.stringValue = "Navigation failed: \(error.localizedDescription)"
    status.isHidden = false
    updateNavigation(updateAddress: false)
  }
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
    return nil
  }
  func destroy() {
    destroyed = true
    nativeChooserGeneration &+= 1
    if let nativeContextObserver {
      NotificationCenter.default.removeObserver(nativeContextObserver)
    }
    nativeContextObserver = nil
    closeTextMode()
    capture.destroy()
    nativeClient.close()
    if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    escapeMonitor = nil
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView?.uiDelegate = nil
    webView = nil
    clip.removeFromSuperview()
  }
}

@_cdecl("desk_browser_create_card")
public func deskBrowserCreateCard(
  _ parentPointer: UnsafeMutableRawPointer?, _ id: UInt64, _ startWeb: UInt8
) -> UnsafeMutableRawPointer? {
  guard Thread.isMainThread, let parentPointer, startWeb <= 1 else { return nil }
  let parentAddress = UInt(bitPattern: parentPointer)
  let address = MainActor.assumeIsolated {
    guard let raw = UnsafeMutableRawPointer(bitPattern: parentAddress) else { return UInt(0) }
    let parent = Unmanaged<NSView>.fromOpaque(raw).takeUnretainedValue()
    return UInt(
      bitPattern: Unmanaged.passRetained(Browser(parent: parent, id: id, startWeb: startWeb == 1))
        .toOpaque())
  }
  return UnsafeMutableRawPointer(bitPattern: address)
}

@_cdecl("desk_browser_set_frame")
public func deskBrowserSetFrame(
  _ pointer: UnsafeMutableRawPointer?, _ x: Double, _ y: Double,
  _ width: Double, _ height: Double, _ zoom: Double, _ viewportWidth: Double,
  _ viewportHeight: Double
) {
  guard Thread.isMainThread, let pointer else { return }
  let address = UInt(bitPattern: pointer)
  MainActor.assumeIsolated {
    guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
    Unmanaged<Browser>.fromOpaque(raw).takeUnretainedValue().setFrame(
      x: x, y: y, width: width, height: height, zoom: zoom,
      viewportWidth: viewportWidth, viewportHeight: viewportHeight)
  }
}

@_cdecl("desk_browser_set_occluders")
public func deskBrowserSetOccluders(
  _ pointer: UnsafeMutableRawPointer?,
  _ x1: Double, _ y1: Double, _ w1: Double, _ h1: Double,
  _ x2: Double, _ y2: Double, _ w2: Double, _ h2: Double
) {
  guard Thread.isMainThread, let pointer else { return }
  let address = UInt(bitPattern: pointer)
  MainActor.assumeIsolated {
    guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
    Unmanaged<Browser>.fromOpaque(raw).takeUnretainedValue().setOccluders([
      CGRect(x: x1, y: y1, width: w1, height: h1),
      CGRect(x: x2, y: y2, width: w2, height: h2),
    ])
  }
}

@_cdecl("desk_browser_set_selected")
public func deskBrowserSetSelected(_ pointer: UnsafeMutableRawPointer?, _ selected: UInt8) {
  guard Thread.isMainThread, let pointer else { return }
  let address = UInt(bitPattern: pointer)
  MainActor.assumeIsolated {
    guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
    let browser = Unmanaged<Browser>.fromOpaque(raw).takeUnretainedValue()
    if browser.selected && selected != 1 {
      browser.nativeChooserGeneration &+= 1
      browser.closeTextMode(reason: "Text operation cancelled: this card is no longer selected.")
      browser.capture.cancelPendingFocus()
    }
    browser.selected = selected == 1
  }
}

@_cdecl("desk_browser_destroy")
public func deskBrowserDestroy(_ pointer: UnsafeMutableRawPointer?) {
  guard Thread.isMainThread, let pointer else { return }
  let address = UInt(bitPattern: pointer)
  MainActor.assumeIsolated {
    guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
    let browser = Unmanaged<Browser>.fromOpaque(raw).takeRetainedValue()
    browser.destroy()
  }
}
