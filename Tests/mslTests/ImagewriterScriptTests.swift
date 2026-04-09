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
        XCTAssertTrue(script.contains("IMAGE_SIZE_MB is required; msl install must pass an explicit size"))
        XCTAssertFalse(script.contains("IMAGE_SIZE_MB=\"${IMAGE_SIZE_MB:-65536}\""))
    }

    func testImagewriterGuestBuilderRequiresExplicitSize() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/imagewriter-build-guest.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("size-mb is required; msl install must pass an explicit size"))
        XCTAssertFalse(script.contains("DEFAULT_SIZE_MB"))
        XCTAssertTrue(script.contains("--size-mb <n>"))
    }
}
