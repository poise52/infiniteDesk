import AppKit

@MainActor
final class DesktopOverviewController: NSObject, NSWindowDelegate {
  private var panel: DesktopOverviewPanel?
  private var overview: DesktopOverviewView?
  private var onSelect: ((UUID) -> Void)?
  private var onCancel: (() -> Void)?
  var onChange: (() -> Void)?

  var isVisible: Bool { panel != nil }
  var isKey: Bool { panel?.isKeyWindow ?? false }
  var windowNumber: Int? { panel?.windowNumber }
  var selectedID: UUID? { overview?.selectedID }

  @discardableResult
  func show(windows: [DesktopWindow], camera: DesktopCameraSnapshot, focusedID: UUID?,
    backToFront: [UUID] = [], onSelect: @escaping (UUID) -> Void,
    onCancel: @escaping () -> Void) -> Bool {
    guard NSScreen.screens.count == 1, let screen = NSScreen.screens.first else { return false }
    dismiss()
    self.onSelect = onSelect
    self.onCancel = onCancel
    let panel = DesktopOverviewPanel(contentRect: screen.visibleFrame,
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .floating
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.isReleasedWhenClosed = false
    panel.title = "InfiniteDesk workspace overview"
    panel.setAccessibilityLabel("InfiniteDesk workspace overview")
    panel.delegate = self
    let view = DesktopOverviewView(frame: CGRect(origin: .zero, size: screen.visibleFrame.size),
      displaySize: screen.frame.size, windows: windows, camera: camera,
      focusedID: focusedID, backToFront: backToFront)
    view.onSelect = { [weak self] id in
      guard let self else { return }
      let callback = self.onSelect
      self.dismiss()
      callback?(id)
    }
    view.onCancel = { [weak self] in self?.cancel() }
    view.onSelectionChange = { [weak self] in self?.onChange?() }
    panel.contentView = view
    self.panel = panel
    overview = view
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(view)
    self.onChange?()
    return true
  }

  func update(windows: [DesktopWindow], camera: DesktopCameraSnapshot, backToFront: [UUID]? = nil) {
    overview?.update(windows: windows, camera: camera, backToFront: backToFront)
  }

  func cancel() {
    guard panel != nil else { return }
    let callback = onCancel
    dismiss()
    callback?()
  }

  func windowDidResignKey(_ notification: Notification) { cancel() }
  func windowDidBecomeKey(_ notification: Notification) { if panel != nil { onChange?() } }

  private func dismiss() {
    let closing = panel
    panel = nil
    overview = nil
    onSelect = nil
    onCancel = nil
    closing?.delegate = nil
    closing?.orderOut(nil)
    closing?.close()
    if closing != nil { onChange?() }
  }
}

@MainActor
private final class DesktopOverviewPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
private final class DesktopOverviewView: NSView {
  var onSelect: ((UUID) -> Void)?
  var onCancel: (() -> Void)?
  var onSelectionChange: (() -> Void)?
  private var windows: [DesktopWindow]
  private var camera: DesktopCameraSnapshot
  private let displaySize: CGSize
  private var backToFront: [UUID]
  private(set) var selectedID: UUID?
  private var geometry = DesktopOverviewGeometry()
  private var cards: [UUID: DesktopOverviewCard] = [:]
  private let cardContainer = DesktopOverviewClipView()
  private var iconCache: [pid_t: NSImage] = [:]
  private var knownIconPIDs: Set<pid_t> = []

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  private var viewport: CGRect {
    CGRect(x: 48, y: 94, width: max(1, bounds.width - 96), height: max(1, bounds.height - 186))
  }
  private var cameraFrame: CGRect { CGRect(origin: camera.origin, size: displaySize) }
  private var items: [DesktopOverviewItem] {
    windows.map { DesktopOverviewItem(id: $0.id, frame: $0.worldFrame,
      selectable: Self.selectable($0) && DesktopOverviewGeometry.valid($0.worldFrame)) }
  }

  private static func selectable(_ window: DesktopWindow) -> Bool {
    window.availability != .closed && (window.availability == .available || window.managerMinimized)
  }

  init(frame: CGRect, displaySize: CGSize, windows: [DesktopWindow], camera: DesktopCameraSnapshot,
    focusedID: UUID?, backToFront: [UUID]) {
    self.windows = windows
    self.camera = camera
    self.displaySize = displaySize
    self.backToFront = backToFront.isEmpty
      ? windows.filter { $0.id != focusedID }.map(\.id) + windows.filter { $0.id == focusedID }.map(\.id)
      : backToFront
    selectedID = windows.first { $0.id == focusedID && Self.selectable($0)
      && DesktopOverviewGeometry.valid($0.worldFrame) }?.id
      ?? windows.first { Self.selectable($0) && DesktopOverviewGeometry.valid($0.worldFrame) }?.id
    super.init(frame: frame)
    setAccessibilityElement(false)
    cardContainer.clipsToBounds = true
    addSubview(cardContainer)
    fitAll()
    rebuildCards()
  }

  required init?(coder: NSCoder) { nil }

  func update(windows: [DesktopWindow], camera: DesktopCameraSnapshot, backToFront: [UUID]?) {
    guard self.windows != windows || self.camera != camera || backToFront != nil else { return }
    let needsCards = self.windows != windows || (backToFront != nil && backToFront != self.backToFront)
    let previousSelection = selectedID
    self.windows = windows
    self.camera = camera
    if let backToFront { self.backToFront = backToFront }
    if !items.contains(where: { $0.id == selectedID && $0.selectable }) {
      selectedID = items.first(where: \.selectable)?.id
    }
    if needsCards { rebuildCards() } else { needsDisplay = true }
    if previousSelection != selectedID { onSelectionChange?() }
  }

  private func fitAll() {
    geometry.fit(windows.map(\.worldFrame) + [cameraFrame], in: viewport)
    positionCards()
  }

  private func rebuildCards() {
    for card in cards.values { card.removeFromSuperview() }
    cards.removeAll(keepingCapacity: true)
    let ranks = Dictionary(backToFront.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { _, last in last })
    let ordered = windows.enumerated().sorted {
      let lhs = ranks[$0.element.id] ?? ($0.offset - windows.count)
      let rhs = ranks[$1.element.id] ?? ($1.offset - windows.count)
      return lhs < rhs
    }.map(\.element)
    for window in ordered where DesktopOverviewGeometry.valid(window.worldFrame) {
      if knownIconPIDs.insert(window.pid).inserted {
        iconCache[window.pid] = NSRunningApplication(processIdentifier: window.pid)?.icon
      }
      let card = DesktopOverviewCard(window: window, icon: iconCache[window.pid], selectable: Self.selectable(window))
      card.target = self
      card.action = #selector(activateCard(_:))
      cards[window.id] = card
      cardContainer.addSubview(card)
    }
    positionCards()
  }

  private func positionCards() {
    cardContainer.frame = viewport
    for window in windows {
      guard let card = cards[window.id] else { continue }
      let projected = geometry.viewFrame(window.worldFrame)
      card.frame = projected.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
      card.isHidden = !projected.intersects(viewport)
      card.selected = selectedID == window.id
      card.needsDisplay = true
    }
    needsDisplay = true
  }

  @objc private func activateCard(_ sender: DesktopOverviewCard) {
    guard sender.isEnabled else { return }
    onSelect?(sender.windowID)
  }

  override func keyDown(with event: NSEvent) {
    let next: UUID?
    switch event.keyCode {
    case 53: onCancel?(); return
    case 36, 76:
      if let selectedID, items.contains(where: { $0.id == selectedID && $0.selectable }) { onSelect?(selectedID) }
      return
    case 48:
      next = DesktopOverviewSelection.cycle(from: selectedID,
        by: event.modifierFlags.contains(.shift) ? -1 : 1, items: items)
    case 123: next = DesktopOverviewSelection.move(from: selectedID, toward: .left, items: items)
    case 124: next = DesktopOverviewSelection.move(from: selectedID, toward: .right, items: items)
    case 125: next = DesktopOverviewSelection.move(from: selectedID, toward: .down, items: items)
    case 126: next = DesktopOverviewSelection.move(from: selectedID, toward: .up, items: items)
    default:
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "f", "0": fitAll()
      case "+", "=": zoom(by: 1.2, at: CGPoint(x: viewport.midX, y: viewport.midY))
      case "-": zoom(by: 1 / 1.2, at: CGPoint(x: viewport.midX, y: viewport.midY))
      default: super.keyDown(with: event)
      }
      return
    }
    let previousSelection = selectedID
    selectedID = next
    if let selected = windows.first(where: { $0.id == next }) { geometry.reveal(selected.worldFrame, in: viewport) }
    positionCards()
    if previousSelection != selectedID { onSelectionChange?() }
    if let next, let card = cards[next] {
      NSAccessibility.post(element: card, notification: .focusedUIElementChanged)
    }
  }

  override func cancelOperation(_ sender: Any?) { onCancel?() }

  override func scrollWheel(with event: NSEvent) {
    let delta = event.scrollingDeltaY
    guard delta.isFinite else { return }
    let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.008 : 0.08
    zoom(by: exp(max(-0.5, min(0.5, delta * sensitivity))), at: convert(event.locationInWindow, from: nil))
  }

  override func magnify(with event: NSEvent) {
    zoom(by: max(0.1, 1 + event.magnification), at: convert(event.locationInWindow, from: nil))
  }

  private func zoom(by factor: CGFloat, at point: CGPoint) {
    geometry.zoom(by: factor, at: point)
    positionCards()
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
    drawText("Workspace overview", at: CGPoint(x: 32, y: 24), font: .systemFont(ofSize: 23, weight: .semibold))
    drawText("Select a window to return to work at 1:1", at: CGPoint(x: 33, y: 55),
      font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
    NSColor.separatorColor.setStroke()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: viewport).addClip()
    let current = NSBezierPath(rect: geometry.viewFrame(cameraFrame))
    current.setLineDash([5, 4], count: 2, phase: 0)
    current.lineWidth = 1
    current.stroke()
    NSGraphicsContext.restoreGraphicsState()
    if windows.isEmpty {
      drawText("No registered windows", at: CGPoint(x: viewport.midX - 90, y: viewport.midY),
        font: .systemFont(ofSize: 17), color: .secondaryLabelColor)
    }
    let footer = CGRect(x: 0, y: bounds.height - 76, width: bounds.width, height: 76)
    NSColor.windowBackgroundColor.setFill()
    footer.fill()
    let selected = windows.first { $0.id == selectedID }
    let label = selected.map { "\($0.appName) — \($0.title.isEmpty ? "Untitled window" : $0.title) · page \($0.cameraPage)" }
      ?? "No available window selected"
    drawText(label, at: CGPoint(x: 32, y: bounds.height - 64), font: .systemFont(ofSize: 14, weight: .medium),
      width: bounds.width - 64)
    let zoom = Int((geometry.scale * 100).rounded())
    drawText("\(zoom)% · Scroll / pinch: zoom · F: fit all · Arrows / Tab: select · Enter: open · Esc: cancel",
      at: CGPoint(x: 32, y: bounds.height - 37), font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
  }

  private func drawText(_ text: String, at point: CGPoint, font: NSFont,
    color: NSColor = .labelColor, width: CGFloat? = nil) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    (text as NSString).draw(in: CGRect(x: point.x, y: point.y,
      width: max(1, width ?? (bounds.width - point.x - 24)), height: font.pointSize + 8),
      withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
  }
}

@MainActor
private final class DesktopOverviewClipView: NSView {
  override var isFlipped: Bool { true }
}

@MainActor
private final class DesktopOverviewCard: NSButton {
  let windowID: UUID
  private let appName: String
  private let windowTitle: String
  private let icon: NSImage?
  var selected = false
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { false }

  init(window: DesktopWindow, icon: NSImage?, selectable: Bool) {
    windowID = window.id
    appName = window.appName
    windowTitle = window.title.isEmpty ? "Untitled window" : window.title
    self.icon = icon
    super.init(frame: .zero)
    isBordered = false
    title = "\(appName) — \(windowTitle)"
    isEnabled = selectable
    toolTip = title + " · page \(window.cameraPage) · \(window.availability.rawValue)"
    setAccessibilityLabel(title)
    setAccessibilityHelp("Page \(window.cameraPage). \(window.availability.rawValue). Activate to return to this exact window.")
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    let rectangle = bounds.insetBy(dx: 1.5, dy: 1.5)
    guard rectangle.width > 0, rectangle.height > 0 else { return }
    let path = NSBezierPath(roundedRect: rectangle, xRadius: min(9, rectangle.width / 8), yRadius: min(9, rectangle.height / 8))
    (selected ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.controlBackgroundColor).setFill()
    path.fill()
    (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
    path.lineWidth = selected ? 3 : 1
    path.stroke()
    guard bounds.width > 54, bounds.height > 28 else { return }
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let iconSize: CGFloat = min(24, max(12, bounds.height - 16))
    icon?.draw(in: CGRect(x: 10, y: 10, width: iconSize, height: iconSize), from: .zero,
      operation: .sourceOver, fraction: isEnabled ? 1 : 0.4, respectFlipped: true, hints: nil)
    let left: CGFloat = icon == nil ? 10 : iconSize + 18
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let color = isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor
    (appName as NSString).draw(in: CGRect(x: left, y: 10, width: max(1, bounds.width - left - 10), height: 19),
      withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: color,
        .paragraphStyle: paragraph])
    if bounds.height > 64 {
      (windowTitle as NSString).draw(in: CGRect(x: 12, y: 43, width: max(1, bounds.width - 24), height: bounds.height - 51),
        withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color,
          .paragraphStyle: paragraph])
    }
    NSGraphicsContext.restoreGraphicsState()
  }
}
