import ApplicationServices
import Foundation

func require(_ condition: @autoclosure () -> Bool) {
  if !condition() { fatalError("Text input routing failed") }
}
require(isAllowedTextRole(kAXTextFieldRole, subrole: nil, inWebArea: true))
require(isAllowedTextRole(kAXTextAreaRole, subrole: nil, inWebArea: true))
require(!isAllowedTextRole(kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole, inWebArea: true))
require(!isAllowedTextRole(kAXTextFieldRole, subrole: nil, inWebArea: false))
require(!isAllowedTextRole(kAXButtonRole, subrole: nil, inWebArea: true))
let sourceSize = CGSize(width: 1200, height: 800)
let sourceWindow = CGRect(x: -1440, y: 100, width: 1200, height: 800)
let clicked = CGPoint(x: 0.75, y: 0.25)
require(
  textPointInWindow(normalized: clicked, sourceSize: sourceSize, window: sourceWindow)
    == CGPoint(x: -540, y: 300))
let relocatedWindow = sourceWindow.offsetBy(dx: 1700, dy: -50)
require(
  textPointInWindow(normalized: clicked, sourceSize: sourceSize, window: relocatedWindow)
    == CGPoint(x: 1160, y: 250))
require(
  textPointInWindow(
    normalized: clicked, sourceSize: sourceSize,
    window: CGRect(x: 0, y: 0, width: 1201, height: 800)) == nil)
for point in [
  CGPoint(x: -0.001, y: 0), CGPoint(x: 0, y: -0.001),
  CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: CGFloat.nan, y: 0),
] {
  require(textPointInWindow(normalized: point, sourceSize: sourceSize, window: sourceWindow) == nil)
}
require(textPointInWindow(normalized: .zero, sourceSize: .zero, window: sourceWindow) == nil)
require(
  textPointInWindow(
    normalized: clicked, sourceSize: CGSize(width: CGFloat.infinity, height: 800),
    window: sourceWindow) == nil)
let field = CGRect(x: 30, y: 180, width: 500, height: 40)
require(sameTextGeometry(field, field))
require(!sameTextGeometry(field, field.offsetBy(dx: 0, dy: 1)))
require(!sameTextGeometry(field, CGRect(x: 30, y: 180, width: 501, height: 40)))
let cancelled = WindowTextGate()
cancelled.cancel()
require(cancelled.commit { .success } == nil)
let once = WindowTextGate()
require(once.commit { .success } == .success)
require(once.commit { .success } == nil)
require(!once.isActive())
require(once.canObserve())
once.cancel()
require(!once.canObserve())

// All mock state is locked; the production retry code runs on a serial worker queue.
final class ReplacementFixture: @unchecked Sendable {
  private let lock = NSLock()
  private let samples: [TextReadbackSample]
  private let writeResult: AXError?
  private var writes = 0
  private var reads = 0
  private var result: TextReplacementResult?
  private var ranOnMain = false

  init(writeResult: AXError?, samples: [TextReadbackSample]) {
    self.writeResult = writeResult
    self.samples = samples
  }

  func write() -> AXError? {
    lock.withLock {
      writes += 1
      ranOnMain = ranOnMain || Thread.isMainThread
      return writeResult
    }
  }

  func read() -> TextReadbackSample {
    lock.withLock {
      let sample = samples[min(reads, samples.count - 1)]
      reads += 1
      ranOnMain = ranOnMain || Thread.isMainThread
      return sample
    }
  }

  func finish(_ result: TextReplacementResult) {
    lock.withLock { self.result = result }
  }

  func verify(_ expected: TextReplacementResult, reads expectedReads: Int) {
    lock.withLock {
      require(writes == 1)
      require(reads == expectedReads)
      require(result == expected)
      require(!ranOnMain)
    }
  }
}

func checkReplacement(
  _ expected: TextReplacementResult, samples: [TextReadbackSample], reads: Int,
  writeResult: AXError? = .success, expired: Bool = false
) {
  let fixture = ReplacementFixture(writeResult: writeResult, samples: samples)
  let queue = DispatchQueue(label: "dev.infinitedesk.test.text-readback")
  let finished = DispatchSemaphore(value: 0)
  queue.async {
    submitTextReplacement(
      on: queue, text: "desk-A-проверка", attempts: 3, retryDelay: .nanoseconds(0),
      deadline: expired ? .now() - .seconds(1) : .now() + .seconds(5),
      write: { fixture.write() }, read: { fixture.read() },
      completion: {
        fixture.finish($0)
        finished.signal()
      })
  }
  require(finished.wait(timeout: .now() + .seconds(10)) == .success)
  fixture.verify(expected, reads: reads)
}

checkReplacement(
  .confirmed, samples: [.value("TARGET-A"), .value(nil), .value("desk-A-проверка")], reads: 3)
checkReplacement(.unconfirmed, samples: [.value("TARGET-A")], reads: 3)
checkReplacement(
  .contextChanged, samples: [.value("TARGET-A"), .contextChanged, .value("desk-A-проверка")],
  reads: 2)
checkReplacement(
  .rejected(.attributeUnsupported), samples: [], reads: 0, writeResult: .attributeUnsupported)
checkReplacement(
  .confirmed, samples: [.value("TARGET-A"), .value("desk-A-проверка")], reads: 2,
  writeResult: .cannotComplete)
checkReplacement(
  .ambiguous(.cannotComplete), samples: [.value("TARGET-A")], reads: 3,
  writeResult: .cannotComplete)
checkReplacement(
  .ambiguous(.cannotComplete), samples: [.contextChanged], reads: 1,
  writeResult: .cannotComplete)
checkReplacement(.cancelled, samples: [], reads: 0, writeResult: nil)
checkReplacement(.unconfirmed, samples: [], reads: 0, expired: true)
print("Text input routing tests passed")
