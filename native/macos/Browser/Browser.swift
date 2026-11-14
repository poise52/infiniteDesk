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
  var onClick: ((CGPoint) -> Void)?
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
  let returnToWeb = NSButton(title: "Web", target: nil, action: nil)
  let openApp = NSButton(title: "Open app", target: nil, action: nil)
  let focusWindow = NSButton(title: "Focus window", target: nil, action: nil)
  let textMode = NSButton(title: "Text…", target: nil, action: nil)
  let pickField = NSButton(title: "Pick field", target: nil, action: nil)
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
    returnToWeb.target = self
    returnToWeb.action = #selector(showWeb)
    openApp.target = self
    openApp.action = #selector(openSourceApplication)
    focusWindow.target = self
    focusWindow.action = #selector(focusSourceWindow)
    textMode.target = self
    textMode.action = #selector(beginTextMode)
    pickField.target = self
    pickField.action = #selector(toggleFieldPicking)
    pickField.setAccessibilityLabel("Pick a Chrome page field from the preview")
    pickField.setAccessibilityHelp(
      "Arm field selection, then click a field in the preview. Escape cancels.")
    textMode.setAccessibilityHelp("Select Chrome's currently focused editable page field")
    textSend.target = self
    textSend.action = #selector(sendTextValue)
    textEditor.placeholderString = "Replacement text"
    textEditor.setAccessibilityLabel("Replacement text for the selected Chrome field")
    textEditor.setAccessibilityHelp("Replace writes the entire field value. Escape cancels.")
    textSend.setAccessibilityHelp("Replace the entire value in the identified Chrome field")
    textLabel.isHidden = true
    textEditor.isHidden = true
    textSend.isHidden = true
    textMode.isHidden = true
    pickField.isHidden = true
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
      self.pickField.isEnabled = false
      self.textMode.isEnabled = false
    }
    capture.onUpdate = { [weak self] message, started in
      guard let self else { return }
      self.status.stringValue = message
      self.status.isHidden = false
      self.openApp.isEnabled = self.capture.canOpenApplication
      self.focusWindow.isEnabled = self.capture.canFocusWindow
      self.textMode.isHidden = !self.capture.canFocusWindow || self.capture.textTarget == nil
      self.pickField.isHidden = self.textMode.isHidden
      self.pickField.isEnabled = self.capture.canFocusWindow
      self.textMode.isEnabled = self.capture.canFocusWindow
      self.closeTextMode()
      if started {
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
    surface.addSubview(returnToWeb)
    surface.addSubview(openApp)
    surface.addSubview(focusWindow)
    surface.addSubview(status)
    surface.addSubview(textMode)
    surface.addSubview(pickField)
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
          isRepeat: event.isARepeat, selected: self.selected && !self.preview.isHidden,
          focus: { self.focusSourceWindow() })
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
      status.stringValue = "Choose Web or Window…"
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
    setFrame(address, NSRect(x: 106, y: 9, width: max(1, width - 220), height: 25))
    setFrame(chooseWindow, NSRect(x: width - 106, y: 7, width: 100, height: 30))
    setFrame(returnToWeb, NSRect(x: 6, y: 7, width: 70, height: 30))
    setFrame(focusWindow, NSRect(x: 80, y: 7, width: 110, height: 30))
    setFrame(openApp, NSRect(x: 194, y: 7, width: 82, height: 30))
    setFrame(textMode, NSRect(x: 280, y: 7, width: 62, height: 30))
    setFrame(pickField, NSRect(x: 346, y: 7, width: 94, height: 30))
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
    var remaining = [clip.bounds]
    for blocker in clip.occluders {
      remaining = remaining.flatMap { rect -> [CGRect] in
        let overlap = rect.intersection(blocker)
        guard !overlap.isNull, !overlap.isEmpty else { return [rect] }
        return [
          CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
          CGRect(
            x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
          CGRect(
            x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
          CGRect(
            x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX,
            height: overlap.height),
        ].filter { !$0.isEmpty }
      }
    }
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
    pickField.title = "Pick field"
    pickField.state = .off
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
    pickField.title = "Cancel pick"
    pickField.state = .on
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
      status.stringValue = "No captured field at that point; choose Pick field and retry."
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
  @objc func selectWindow() {
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
    closeTextMode()
    textMode.isHidden = true
    pickField.isHidden = true
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
    closeTextMode()
    capture.destroy()
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
