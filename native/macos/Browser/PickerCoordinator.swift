import AppKit
@preconcurrency import ScreenCaptureKit

@MainActor
final class WindowPickerCoordinator: NSObject, SCContentSharingPickerObserver {
  static let shared = WindowPickerCoordinator()
  private final class WeakOwner {
    weak var value: WindowCapture?
    init(_ value: WindowCapture) { self.value = value }
  }
  private var owners: [ObjectIdentifier: WeakOwner] = [:]
  private var pending: WeakOwner?
  private var pendingCancelled = false
  private var registered = false

  func present(_ owner: WindowCapture) -> Bool {
    guard pending == nil else { return false }
    owners[ObjectIdentifier(owner)] = WeakOwner(owner)
    pending = WeakOwner(owner)
    pendingCancelled = false
    let picker = SCContentSharingPicker.shared
    var configuration = SCContentSharingPickerConfiguration()
    configuration.allowedPickerModes = .singleWindow
    if let bundle = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [bundle] }
    picker.defaultConfiguration = configuration
    if !registered {
      picker.add(self)
      registered = true
    }
    picker.isActive = true
    picker.present(using: .window)
    return true
  }

  func release(_ owner: WindowCapture) {
    owners.removeValue(forKey: ObjectIdentifier(owner))
    if pending?.value === owner { pendingCancelled = true }
    updateActivity()
  }

  private func updateActivity() {
    owners = owners.filter { $0.value.value != nil }
    guard owners.isEmpty, pending == nil, registered else { return }
    SCContentSharingPicker.shared.remove(self)
    SCContentSharingPicker.shared.isActive = false
    registered = false
  }

  private func takePending() -> WindowCapture? {
    let owner = pendingCancelled ? nil : pending?.value
    pending = nil
    pendingCancelled = false
    updateActivity()
    return owner
  }

  nonisolated func contentSharingPicker(
    _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
  ) {
    let streamID = stream.map(ObjectIdentifier.init)
    Task { @MainActor in
      if let streamID {
        self.owners.values.compactMap(\.value).first { $0.ownsPickerStream(streamID) }?
          .pickerCancelled()
      } else {
        self.takePending()?.pickerCancelled()
      }
    }
  }

  nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
    let message = error.localizedDescription
    Task { @MainActor in self.takePending()?.pickerFailed(message) }
  }

  nonisolated func contentSharingPicker(
    _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?
  ) {
    let streamID = stream.map(ObjectIdentifier.init)
    Task { @MainActor in
      if let streamID {
        self.owners.values.compactMap(\.value).first { $0.ownsPickerStream(streamID) }?
          .pickerUpdated(filter, streamID: streamID)
      } else {
        self.takePending()?.pickerUpdated(filter, streamID: nil)
      }
    }
  }
}
