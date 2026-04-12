import XCTest
@testable import msl

final class StopCommandTests: XCTestCase {
    func testStopAppParsesWithoutInstance() throws {
        XCTAssertNoThrow(try StopCommand.parse(["--app"]))
        XCTAssertNoThrow(try StopCommand.parse(["--app", "--all"]))
    }

    func testStopAppRejectsPositionalInstance() {
        XCTAssertThrowsError(try StopCommand.parse(["--app", "ubuntu"]))
    }

    func testStopAppRejectsGlobalInstance() {
        XCTAssertThrowsError(try MSLCommand.parse(["--instance", "ubuntu", "stop", "--app"])) { error in
            XCTAssertTrue(String(describing: error).contains("`stop --app` cannot be combined with an instance argument"))
        }
    }
}
