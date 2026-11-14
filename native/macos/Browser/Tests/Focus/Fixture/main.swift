import AppKit
import Foundation

@MainActor final class Fixture: NSObject, NSApplicationDelegate {
  var windows: [NSWindow] = []
  func applicationDidFinishLaunching(_ notification: Notification) {
    guard CommandLine.arguments.count == 2 else { exit(2) }
    let a = NSWindow(
      contentRect: CGRect(x: 140, y: 200, width: 220, height: 180),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let b = NSWindow(
      contentRect: CGRect(x: 440, y: 200, width: 240, height: 200),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    a.isReleasedWhenClosed = false
    b.isReleasedWhenClosed = false
    a.title = "InfiniteDesk Focus Fixture A"
    b.title = "InfiniteDesk Focus Fixture B"
    a.orderFront(nil)
    b.makeKeyAndOrderFront(nil)
    NSApp.activate()
    windows = [a, b]
    let line = "\(a.windowNumber) \(b.windowNumber)\n"
    do { try line.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8) } catch
    { exit(1) }
  }
}
let app = NSApplication.shared
let delegate = Fixture()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
