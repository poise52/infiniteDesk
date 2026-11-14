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
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard bounds.contains(local), let child = subviews.first, child.frame.contains(local) else {
      return nil
    }
    return super.hitTest(point)
  }
}

@MainActor private final class BrowserSurface: NSView {
  override var isFlipped: Bool { true }
}

@MainActor
private final class Browser: NSObject, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
  let parent: NSView
  let clip = BrowserClip()
  let surface = BrowserSurface()
  let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
  let address = NSTextField()
  let back = NSButton(title: "‹", target: nil, action: nil)
  let forward = NSButton(title: "›", target: nil, action: nil)
  let home = NSButton(title: "⌂", target: nil, action: nil)
  let status = NSTextField(labelWithString: "")
  let capture = WindowCapture()
  let preview = NSView()
  let chooseWindow = NSButton(title: "Window…", target: nil, action: nil)
  let returnToWeb = NSButton(title: "Web", target: nil, action: nil)
  let openApp = NSButton(title: "Open app", target: nil, action: nil)
  let chromeHeight: CGFloat = 44
  var escapeMonitor: Any?

  init(parent: NSView) {
    self.parent = parent
    super.init()
    clip.wantsLayer = true
    clip.layer?.masksToBounds = true
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
    preview.wantsLayer = true
    preview.layer?.addSublayer(capture.layer)
    preview.isHidden = true
    returnToWeb.isHidden = true
    openApp.isHidden = true
    capture.onUpdate = { [weak self] message, started in
      guard let self else { return }
      self.status.stringValue = message
      self.status.isHidden = false
      self.openApp.isEnabled = self.capture.canOpenApplication
      if started {
        self.webView.isHidden = true
        self.preview.isHidden = false
        self.back.isHidden = true
        self.forward.isHidden = true
        self.home.isHidden = true
        self.address.isHidden = true
        self.returnToWeb.isHidden = false
        self.openApp.isHidden = !self.capture.canOpenApplication
      }
    }
    surface.addSubview(back)
    surface.addSubview(forward)
    surface.addSubview(home)
    surface.addSubview(address)
    surface.addSubview(webView)
    surface.addSubview(preview)
    surface.addSubview(chooseWindow)
    surface.addSubview(returnToWeb)
    surface.addSubview(openApp)
    surface.addSubview(status)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    parent.addSubview(clip)
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let handled = MainActor.assumeIsolated {
        guard let self, let window = self.parent.window, event.window === window,
          event.keyCode == 53,
          event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
          let responder = window.firstResponder
        else { return false }
        let inBrowser =
          (responder as? NSView)?.isDescendant(of: self.clip) == true
          || self.address.currentEditor() === responder
        guard inBrowser else { return false }
        window.makeFirstResponder(self.parent)
        return true
      }
      return handled ? nil : event
    }
    updateNavigation()
    goHome()
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
    setFrame(openApp, NSRect(x: 80, y: 7, width: 100, height: 30))
    setFrame(webView, NSRect(x: 0, y: chromeHeight, width: width, height: height - chromeHeight))
    setFrame(preview, NSRect(x: 0, y: chromeHeight, width: width, height: height - chromeHeight))
    capture.layer.frame = preview.bounds
    setFrame(status, NSRect(x: 8, y: height - 24, width: max(1, width - 16), height: 18))
    status.isHidden = status.stringValue.isEmpty
  }

  @objc func selectWindow() { capture.selectWindow() }
  @objc func openSourceApplication() { capture.openApplication() }
  @objc func showWeb() {
    capture.stop()
    webView.isHidden = false
    preview.isHidden = true
    back.isHidden = false
    forward.isHidden = false
    home.isHidden = false
    address.isHidden = false
    returnToWeb.isHidden = true
    openApp.isHidden = true
    status.stringValue = ""
    status.isHidden = true
  }
  @objc func goBack() { if webView.canGoBack { webView.goBack() } }
  @objc func goForward() { if webView.canGoForward { webView.goForward() } }
  @objc func goHome() {
    guard let url = URL(string: homeAddress) else { return }
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
    webView.load(URLRequest(url: url))
  }
  func updateNavigation(updateAddress: Bool = true) {
    back.isEnabled = webView.canGoBack
    forward.isEnabled = webView.canGoForward
    guard updateAddress else { return }
    if let url = webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
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
    capture.destroy()
    if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    escapeMonitor = nil
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    clip.removeFromSuperview()
  }
}

@_cdecl("desk_browser_create")
public func deskBrowserCreate(_ parentPointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
{
  guard Thread.isMainThread, let parentPointer else { return nil }
  let parentAddress = UInt(bitPattern: parentPointer)
  let address = MainActor.assumeIsolated {
    guard let raw = UnsafeMutableRawPointer(bitPattern: parentAddress) else { return UInt(0) }
    let parent = Unmanaged<NSView>.fromOpaque(raw).takeUnretainedValue()
    return UInt(bitPattern: Unmanaged.passRetained(Browser(parent: parent)).toOpaque())
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
