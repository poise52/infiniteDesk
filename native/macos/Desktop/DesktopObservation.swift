@preconcurrency import ApplicationServices
import Foundation

struct DesktopObservationEvent: Hashable, Sendable {
  enum Kind: Sendable { case focus, geometry, destroyed, focusRetry, geometryRetry }
  let session: UUID
  let windowID: UUID?
  let kind: Kind
}

protocol DesktopAXObserverHandle: AnyObject {
  func subscribe(
    _ element: AXUIElement, notification: String, event: DesktopObservationEvent
  ) -> AXError
  func unsubscribe(windowID: UUID) -> Bool
  func cancel()
}

protocol DesktopObservationProvider: AnyObject {
  func create(
    pid: pid_t, receive: @escaping @Sendable (DesktopObservationEvent) -> Void
  ) throws -> any DesktopAXObserverHandle
}

// C callbacks carry never-reused integer keys, not object pointers. Retiring a route is safe even
// if its callback is already queued: a missing key is ignored and backend session checks reject races.
private final class DesktopObserverRoutes: @unchecked Sendable {
  struct Route: Sendable {
    let event: DesktopObservationEvent
    let receive: @Sendable (DesktopObservationEvent) -> Void
  }
  static let shared = DesktopObserverRoutes()
  private let lock = NSLock()
  private var next: UInt = 1
  private var routes: [UInt: Route] = [:]

  func insert(_ route: Route) -> UInt? {
    lock.lock()
    defer { lock.unlock() }
    guard next < UInt.max else { return nil }
    let key = next
    next += 1
    routes[key] = route
    return key
  }

  func remove(_ key: UInt) {
    lock.lock()
    routes.removeValue(forKey: key)
    lock.unlock()
  }

  func deliver(_ key: UInt) {
    lock.lock()
    let route = routes[key]
    lock.unlock()
    if let route { route.receive(route.event) }
  }
}

private let desktopAXObserverCallback: AXObserverCallback = { _, _, _, refcon in
  guard let refcon else { return }
  DesktopObserverRoutes.shared.deliver(UInt(bitPattern: refcon))
}

// Subscription state is confined to the worker queue. Main-run-loop callbacks only route immutable
// event IDs into the inbox; attach/detach retain the immutable observer until source removal finishes.
private final class DesktopSystemObserver: DesktopAXObserverHandle, @unchecked Sendable {
  struct Subscription {
    let element: AXUIElement
    let notification: String
    let windowID: UUID?
    let route: UInt
  }
  let observer: AXObserver
  private let source: CFRunLoopSource
  private let receive: @Sendable (DesktopObservationEvent) -> Void
  private var subscriptions: [Subscription] = []
  private var stopped = false

  init(
    pid: pid_t, receive: @escaping @Sendable (DesktopObservationEvent) -> Void
  ) throws {
    var observer: AXObserver?
    let status = AXObserverCreate(pid, desktopAXObserverCallback, &observer)
    guard status == .success, let observer else {
      throw DesktopWindowError.message("Accessibility notifications unavailable (AX \(status.rawValue)).")
    }
    self.observer = observer
    self.source = AXObserverGetRunLoopSource(observer)
    self.receive = receive
    DispatchQueue.main.async { [self] in
      CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
  }

  func subscribe(
    _ element: AXUIElement, notification: String, event: DesktopObservationEvent
  ) -> AXError {
    guard !stopped,
      let route = DesktopObserverRoutes.shared.insert(.init(event: event, receive: receive)),
      let pointer = UnsafeMutableRawPointer(bitPattern: route)
    else { return .failure }
    let status = AXObserverAddNotification(observer, element, notification as CFString, pointer)
    if status == .success {
      subscriptions.append(.init(
        element: element, notification: notification, windowID: event.windowID, route: route))
    } else {
      DesktopObserverRoutes.shared.remove(route)
    }
    return status
  }

  func unsubscribe(windowID: UUID) -> Bool {
    let removed = subscriptions.filter { $0.windowID == windowID }
    subscriptions.removeAll { $0.windowID == windowID }
    var clean = true
    for item in removed {
      DesktopObserverRoutes.shared.remove(item.route)
      let status = AXObserverRemoveNotification(observer, item.element, item.notification as CFString)
      if status != .success && status != .notificationNotRegistered && status != .invalidUIElement {
        clean = false
      }
    }
    return clean
  }

  func cancel() {
    guard !stopped else { return }
    stopped = true
    for item in subscriptions { DesktopObserverRoutes.shared.remove(item.route) }
    subscriptions.removeAll()
    let source = DesktopObserverSource(observer: observer, source: source)
    DispatchQueue.main.async { source.detach() }
  }

  deinit {
    if !stopped {
      for item in subscriptions { DesktopObserverRoutes.shared.remove(item.route) }
      let source = DesktopObserverSource(observer: observer, source: source)
      DispatchQueue.main.async { source.detach() }
    }
  }
}

private final class DesktopObserverSource: @unchecked Sendable {
  let observer: AXObserver
  let source: CFRunLoopSource
  init(observer: AXObserver, source: CFRunLoopSource) {
    self.observer = observer
    self.source = source
  }
  func detach() { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
}

final class SystemDesktopObservationProvider: DesktopObservationProvider {
  func create(
    pid: pid_t, receive: @escaping @Sendable (DesktopObservationEvent) -> Void
  ) throws -> any DesktopAXObserverHandle {
    try DesktopSystemObserver(pid: pid, receive: receive)
  }
}

// Callback threads merge repeated notifications into one bounded mailbox. A burst schedules at
// most one worker task; new notifications during a drain schedule only the next bounded batch.
final class DesktopObservationInbox: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: Set<DesktopObservationEvent> = []
  private var order: [DesktopObservationEvent] = []
  private var head = 0
  private var scheduled = false
  private let queue: DispatchQueue
  private let receive: @Sendable ([DesktopObservationEvent]) -> Void

  init(queue: DispatchQueue, receive: @escaping @Sendable ([DesktopObservationEvent]) -> Void) {
    self.queue = queue
    self.receive = receive
  }

  func submit(_ event: DesktopObservationEvent) {
    lock.lock()
    if pending.insert(event).inserted { order.append(event) }
    guard !scheduled else {
      lock.unlock()
      return
    }
    scheduled = true
    lock.unlock()
    queue.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in self?.drain() }
  }

  private func drain() {
    lock.lock()
    let end = min(head + 4, order.count)
    let events = Array(order[head..<end])
    head = end
    pending.subtract(events)
    if head == order.count {
      order.removeAll(keepingCapacity: true)
      head = 0
    } else if head > 1024 && head > order.count / 2 {
      order.removeFirst(head)
      head = 0
    }
    scheduled = !pending.isEmpty
    let again = scheduled
    lock.unlock()
    receive(events)
    if again {
      queue.async { [weak self] in self?.drain() }
    }
  }

  func discard(session: UUID, windowID: UUID? = nil) {
    lock.lock()
    let removed = pending.filter { $0.session == session && (windowID == nil || $0.windowID == windowID) }
    pending.subtract(removed)
    order = order[head...].filter { !removed.contains($0) }
    head = 0
    lock.unlock()
  }

  func clear() {
    lock.lock()
    pending.removeAll()
    order.removeAll()
    head = 0
    lock.unlock()
  }
}
