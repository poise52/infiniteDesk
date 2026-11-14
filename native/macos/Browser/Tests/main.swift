import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor final class TestRunner: NSObject, NSApplicationDelegate {
  let first = WindowCapture()
  let second = WindowCapture()
  var firstWindow: NSWindow?
  var secondWindow: NSWindow?
  var firstColor = ""
  var secondColor = ""
  var firstRGB = "unavailable"
  var secondRGB = "unavailable"
  var stopped = false
  var receivedAfterStop = false
  var captureError: String?
  var firstExpectedSize = CGSize(width: 200, height: 200)

  func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }

  func centerColor(_ image: CGImage) -> (name: String, rgb: String) {
    guard
      let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return ("unknown", "context unavailable") }
    context.draw(
      image,
      in: CGRect(
        x: -image.width / 2, y: -image.height / 2,
        width: image.width, height: image.height))
    guard let data = context.data else { return ("unknown", "pixels unavailable") }
    let pixels = data.bindMemory(to: UInt8.self, capacity: 4)
    let (r, g, b) = (Int(pixels[0]), Int(pixels[1]), Int(pixels[2]))
    let rgb = "\(r),\(g),\(b)"
    if r > 160 && r > g * 2 && r > b * 2 { return ("red", rgb) }
    if g > 160 && g > r * 2 && g > b * 2 { return ("green", rgb) }
    if b > 160 && b > r * 2 && b > g * 2 { return ("blue", rgb) }
    if r > 160 && g > 160 && r > b * 2 && g > b * 2 { return ("yellow", rgb) }
    return ("unknown", rgb)
  }

  func checkGeometry(_ capture: WindowCapture, image: CGImage, expectedSize: CGSize) {
    guard let geometry = capture.displayedGeometry else {
      captureError = "complete frame has no valid point-selection geometry"
      return
    }
    let bounds = CGRect(x: 0, y: 0, width: 554, height: 380)
    guard
      let point = geometry.normalizedPoint(
        CGPoint(x: bounds.midX, y: bounds.midY),
        in: bounds, flipped: false), abs(point.x - 0.5) < 0.01, abs(point.y - 0.5) < 0.01,
      abs(geometry.sourceSize.width - expectedSize.width) <= 0.5,
      abs(geometry.sourceSize.height - expectedSize.height) <= 0.5,
      image.width > 1, image.height > 1, image.width <= 1600, image.height <= 1200
    else {
      let point = geometry.normalizedPoint(
        CGPoint(x: bounds.midX, y: bounds.midY), in: bounds, flipped: false)
      captureError =
        "frame point-selection mismatch: image=\(image.width)×\(image.height), contentPixels=\(geometry.contentPixels), sourceSize=\(geometry.sourceSize), expected=\(expectedSize), center=\(String(describing: point))"
      return
    }
  }

  func setColor(_ window: NSWindow, _ color: NSColor) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    window.contentView?.layer?.backgroundColor = color.cgColor
    CATransaction.commit()
  }

  func waitFor(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<100 {
      if captureError != nil { return false }
      if condition() { return true }
      try await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  func run() async {
    do {
      func makeWindow(_ x: CGFloat, _ color: NSColor, size: CGSize) -> NSWindow {
        let window = NSWindow(
          contentRect: NSRect(x: x, y: 200, width: size.width, height: size.height),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true
        setColor(window, color)
        window.orderFrontRegardless()
        return window
      }
      let a = makeWindow(200, .red, size: CGSize(width: 200, height: 200))
      let b = makeWindow(500, .blue, size: CGSize(width: 1800, height: 1400))
      firstWindow = a
      secondWindow = b
      var targets: [SCWindow] = []
      for _ in 0..<50 {
        let content = try await SCShareableContent.currentProcess
        targets = content.windows.filter {
          $0.windowID == CGWindowID(a.windowNumber) || $0.windowID == CGWindowID(b.windowNumber)
        }
        if targets.count == 2 { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard let targetA = targets.first(where: { $0.windowID == CGWindowID(a.windowNumber) }),
        let targetB = targets.first(where: { $0.windowID == CGWindowID(b.windowNumber) })
      else {
        skip("own fixture windows unavailable to ScreenCaptureKit")
        return
      }
      first.onUpdate = { [weak self] message, started in
        if !started && !message.hasPrefix("Capture is suspended;") {
          self?.captureError = "A: " + message
        }
      }
      second.onUpdate = { [weak self] message, started in
        if !started && !message.hasPrefix("Capture is suspended;") {
          self?.captureError = "B: " + message
        }
      }
      first.testOnImage = { [weak self] image in
        guard let self else { return }
        if self.stopped {
          self.receivedAfterStop = true
        } else {
          self.checkGeometry(self.first, image: image, expectedSize: self.firstExpectedSize)
          let sample = self.centerColor(image)
          self.firstColor = sample.name
          self.firstRGB = sample.rgb
        }
      }
      second.testOnImage = { [weak self] image in
        guard let self else { return }
        self.checkGeometry(self.second, image: image, expectedSize: b.frame.size)
        let sample = self.centerColor(image)
        self.secondColor = sample.name
        self.secondRGB = sample.rgb
      }
      let filterA = SCContentFilter(desktopIndependentWindow: targetA)
      let filterB = SCContentFilter(desktopIndependentWindow: targetB)
      // currentProcess redacts SCWindow/frame filter geometry; AppKit owns these fixture sizes.
      first.beginFixture(filterA, sourceSize: a.frame.size, pixelScale: a.backingScaleFactor)
      second.beginFixture(filterB, sourceSize: b.frame.size, pixelScale: b.backingScaleFactor)
      guard try await waitFor({ firstColor == "red" && secondColor == "blue" }) else {
        fail(
          captureError
            ?? "initial red/blue frames missing (A=\(firstColor) [\(firstRGB)], B=\(secondColor) [\(secondRGB)])"
        )
        return
      }
      setColor(a, .green)
      setColor(b, .yellow)
      guard try await waitFor({ firstColor == "green" && secondColor == "yellow" }) else {
        fail(
          captureError
            ?? "green/yellow updates missing (A=\(firstColor) [\(firstRGB)], B=\(secondColor) [\(secondRGB)])"
        )
        return
      }
      firstColor = ""
      firstExpectedSize = b.frame.size
      first.beginFixture(
        SCContentFilter(desktopIndependentWindow: targetB),
        sourceSize: b.frame.size, pixelScale: b.backingScaleFactor)
      guard first.layer.contents == nil, first.displayedGeometry == nil else {
        fail("repick did not clear the old image and geometry")
        return
      }
      setColor(a, .red)
      guard try await waitFor({ firstColor == "yellow" }) else {
        fail(captureError ?? "A→B repick failed or published a late A frame")
        return
      }
      stopped = true
      first.stop()
      guard first.layer.contents == nil else {
        fail("stop did not clear A")
        return
      }
      setColor(b, .blue)
      guard try await waitFor({ secondColor == "blue" }) else {
        fail(captureError ?? "B did not update after stopping A")
        return
      }
      try await Task.sleep(for: .seconds(1))
      guard !receivedAfterStop else {
        fail("A published after stop")
        return
      }
      print(
        "PASS: A red→green, B blue→yellow; A→B repick clears old geometry and ignores late A frames; B→blue after A stop; frame-matched geometry includes downsampling; A did not publish after stop"
      )
      cleanup()
      exit(0)
    } catch { skip(error.localizedDescription) }
  }

  func skip(_ message: String) {
    fputs("SKIP: \(message)\n", stderr)
    cleanup()
    exit(77)
  }
  func fail(_ message: String) {
    fputs("FAIL: \(message)\n", stderr)
    cleanup()
    exit(1)
  }
  func cleanup() {
    first.destroy()
    second.destroy()
    firstWindow?.close()
    secondWindow?.close()
  }
}
let app = NSApplication.shared
let delegate = TestRunner()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
