import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor final class TestRunner: NSObject, NSApplicationDelegate {
  let capture = WindowCapture()
  var window: NSWindow?
  var timer: Timer?
  var sawRed = false
  var sawGreen = false
  var receivedAfterStop = false
  var stopped = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { await run() }
  }

  func centerColor(_ image: CGImage) -> (UInt8, UInt8)? {
    var pixels = [UInt8](repeating: 0, count: 4)
    guard
      let context = CGContext(
        data: &pixels, width: 1, height: 1, bitsPerComponent: 8,
        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(
      image,
      in: CGRect(
        x: -image.width / 2, y: -image.height / 2,
        width: image.width, height: image.height))
    return (pixels[0], pixels[1])
  }

  func run() async {
    do {
      let window = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 200, height: 200),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView?.wantsLayer = true
      window.contentView?.layer?.backgroundColor = NSColor.red.cgColor
      window.orderBack(nil)
      self.window = window
      timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak window] _ in
        MainActor.assumeIsolated {
          guard let layer = window?.contentView?.layer else { return }
          layer.backgroundColor =
            layer.backgroundColor == NSColor.red.cgColor
            ? NSColor.green.cgColor : NSColor.red.cgColor
        }
      }
      var target: SCWindow?
      for _ in 0..<50 {
        let content = try await SCShareableContent.currentProcess
        target = content.windows.first { $0.windowID == CGWindowID(window.windowNumber) }
        if target != nil { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard let target else {
        skip("own fixture window unavailable to ScreenCaptureKit")
        return
      }
      capture.onUpdate = { [weak self] message, started in
        if !started { self?.fail(message) }
      }
      capture.testOnImage = { [weak self] _ in
        guard let self, let content = self.capture.layer.contents,
          CFGetTypeID(content as CFTypeRef) == CGImage.typeID
        else { return }
        let image = content as! CGImage
        guard let (red, green) = self.centerColor(image) else { return }
        if self.stopped {
          self.receivedAfterStop = true
          return
        }
        if red > 160 && Int(red) > Int(green) * 2 { self.sawRed = true }
        if green > 160 && Int(green) > Int(red) * 2 { self.sawGreen = true }
      }
      capture.beginFixture(SCContentFilter(desktopIndependentWindow: target))
      for _ in 0..<100 {
        if sawRed && sawGreen { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard sawRed && sawGreen else {
        fail("did not receive red and green center pixels")
        return
      }
      stopped = true
      capture.stop()
      guard capture.layer.contents == nil else {
        fail("stop did not clear the layer")
        return
      }
      try await Task.sleep(for: .seconds(1))
      guard !receivedAfterStop else {
        fail("frame published after stop")
        return
      }
      print("PASS: fixture capture, red/green center pixels, and stop")
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
    capture.destroy()
    timer?.invalidate()
    window?.close()
  }
}
let app = NSApplication.shared
let delegate = TestRunner()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
