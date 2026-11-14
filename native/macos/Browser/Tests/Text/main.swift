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
