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
print("Text input routing tests passed")
