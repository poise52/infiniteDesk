import AppKit

do {
  if let instance = try DesktopInstance.acquire() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = DesktopApp()
    application.delegate = delegate
    withExtendedLifetime((instance, delegate)) {
      application.run()
    }
  }
} catch {
  FileHandle.standardError.write(Data("InfiniteDesk could not start: \(error.localizedDescription)\n".utf8))
  exit(EXIT_FAILURE)
}
