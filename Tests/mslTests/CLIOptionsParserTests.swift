import XCTest
@testable import mslCore

final class CLIOptionsParserTests: XCTestCase {
    func testParsesGlobalInstanceOption() throws {
        let parsed = try MSLCLIOptionsParser.parseGlobalRuntimeOptions(["--instance", "dev"])
        XCTAssertEqual(parsed.instanceName, "dev")
        XCTAssertEqual(parsed.remainingArguments, [])
    }

    func testStopsParsingAtRunSubcommand() throws {
        let parsed = try MSLCLIOptionsParser.parseGlobalRuntimeOptions([
            "--instance", "dev", "run", "echo", "--instance", "guest"
        ])
        XCTAssertEqual(parsed.instanceName, "dev")
        XCTAssertEqual(parsed.remainingArguments, ["run", "echo", "--instance", "guest"])
    }

    func testStopsParsingAtConfigSubcommand() throws {
        let parsed = try MSLCLIOptionsParser.parseGlobalRuntimeOptions([
            "--instance", "dev", "config", "set", "storageCacheToggles.apt", "false"
        ])
        XCTAssertEqual(parsed.instanceName, "dev")
        XCTAssertEqual(parsed.remainingArguments, ["config", "set", "storageCacheToggles.apt", "false"])
    }

    func testStopsParsingAtImageSubcommand() throws {
        let parsed = try MSLCLIOptionsParser.parseGlobalRuntimeOptions([
            "--instance", "dev", "image", "build", "--profile", "default"
        ])
        XCTAssertEqual(parsed.instanceName, "dev")
        XCTAssertEqual(parsed.remainingArguments, ["image", "build", "--profile", "default"])
    }

    func testStopsParsingAtNetworkSubcommand() throws {
        let parsed = try MSLCLIOptionsParser.parseGlobalRuntimeOptions([
            "--instance", "dev", "network", "reconcile"
        ])
        XCTAssertEqual(parsed.instanceName, "dev")
        XCTAssertEqual(parsed.remainingArguments, ["network", "reconcile"])
    }

    func testRejectsDuplicateInstanceOption() {
        XCTAssertThrowsError(
            try MSLCLIOptionsParser.parseGlobalRuntimeOptions([
                "--instance", "a", "--instance", "b"
            ])
        ) { error in
            XCTAssertEqual(error as? MSLCLIParseError, .duplicateOption(option: "--instance"))
        }
    }

    func testRejectsMissingInstanceValue() {
        XCTAssertThrowsError(
            try MSLCLIOptionsParser.parseGlobalRuntimeOptions(["--instance"])
        ) { error in
            XCTAssertEqual(error as? MSLCLIParseError, .missingValue(option: "--instance"))
        }
    }

    func testRejectsEmptyInstanceValue() {
        XCTAssertThrowsError(
            try MSLCLIOptionsParser.parseGlobalRuntimeOptions(["--instance", "   "])
        ) { error in
            XCTAssertEqual(error as? MSLCLIParseError, .emptyValue(option: "--instance"))
        }
    }
}
