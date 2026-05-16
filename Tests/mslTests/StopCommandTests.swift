import XCTest
@testable import msl

final class StopCommandTests: XCTestCase {
    func testStopAppParsesWithoutInstance() throws {
        XCTAssertNoThrow(try StopCommand.parse(["--app"]))
        XCTAssertNoThrow(try StopCommand.parse(["--app", "--all"]))
        XCTAssertNoThrow(try StopCommand.parse(["--desktop"]))
        XCTAssertNoThrow(try StopCommand.parse(["--desktop", "--all"]))
    }

    func testStopAppRejectsPositionalInstance() {
        XCTAssertThrowsError(try StopCommand.parse(["--app", "ubuntu"]))
        XCTAssertThrowsError(try StopCommand.parse(["--desktop", "ubuntu"]))
    }

    func testStopAppRejectsGlobalInstance() {
        XCTAssertThrowsError(try MSLCommand.parse(["--instance", "ubuntu", "stop", "--app"])) { error in
            XCTAssertTrue(String(describing: error).contains("`stop --app`/`--desktop` cannot be combined with an instance argument"))
        }
        XCTAssertThrowsError(try MSLCommand.parse(["--instance", "ubuntu", "stop", "--desktop"])) { error in
            XCTAssertTrue(String(describing: error).contains("`stop --app`/`--desktop` cannot be combined with an instance argument"))
        }
    }
}
