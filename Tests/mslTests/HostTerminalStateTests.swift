import XCTest
@testable import mslCore

final class HostTerminalStateTests: XCTestCase {
    func testNewlineRecoverySequenceEnablesNewLineMode() {
        XCTAssertEqual(HostTerminalState.newlineRecoverySequence, "\r\u{1b}[20l")
    }
}
