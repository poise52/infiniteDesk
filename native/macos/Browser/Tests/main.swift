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

  func setColor(_ window: NSWindow, _ color: NSColor) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    window.contentView?.layer?.backgroundColor = color.cgColor
    CATransaction.commit()
  }

  func waitFor(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<100 {
      if condition() || captureError != nil { return condition() }
      try await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  func run() async {
    do {
      func makeWindow(_ x: CGFloat, _ color: NSColor) -> NSWindow {
        let window = NSWindow(
          contentRect: NSRect(x: x, y: 200, width: 200, height: 200),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true
        setColor(window, color)
        window.orderBack(nil)
        return window
      }
      let a = makeWindow(200, .red)
      let b = makeWindow(500, .blue)
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
        if !started { self?.captureError = "A: " + message }
      }
      second.onUpdate = { [weak self] message, started in
        if !started { self?.captureError = "B: " + message }
      }
      first.testOnImage = { [weak self] image in
        guard let self else { return }
        if self.stopped {
          self.receivedAfterStop = true
        } else {
          let sample = self.centerColor(image)
          self.firstColor = sample.name
          self.firstRGB = sample.rgb
        }
      }
      second.testOnImage = { [weak self] image in
        guard let self else { return }
        let sample = self.centerColor(image)
        self.secondColor = sample.name
        self.secondRGB = sample.rgb
      }
      first.beginFixture(SCContentFilter(desktopIndependentWindow: targetA))
      second.beginFixture(SCContentFilter(desktopIndependentWindow: targetB))
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
      print("PASS: A red→green, B blue→yellow→blue after A stop; A did not publish after stop")
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
