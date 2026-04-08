import XCTest

final class ImagewriterScriptTests: XCTestCase {
    func testImagewriterSetupScriptUsesStopSubcommand() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/imagewriter-setup.sh"), encoding: .utf8)

        XCTAssertFalse(script.contains("--instance \"$INSTANCE\" --stop"))
        XCTAssertFalse(script.contains("\"$MSL_BIN\" --stop"))
        XCTAssertTrue(script.contains("\"$MSL_BIN\" stop"))
        XCTAssertTrue(script.contains("\"$MSL_BIN\" --instance \"$INSTANCE\" stop"))
    }

    func testImagewriterBuildScriptUsesStopSubcommand() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/imagewriter-build.sh"), encoding: .utf8)

        XCTAssertFalse(script.contains("--instance \"$INSTANCE\" --stop"))
        XCTAssertTrue(script.contains("\"$MSL_BIN\" --instance \"$INSTANCE\" stop"))
    }
}
