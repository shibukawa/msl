import XCTest
@testable import mslCore

final class CLIOptionsParserTests: XCTestCase {
    func testParsesGlobalInstanceShortOption() throws {
        let parsed = try MSLCLIOptionsParser.parseGlobalRuntimeOptions(["-i", "dev"])
        XCTAssertEqual(parsed.instanceName, "dev")
        XCTAssertEqual(parsed.remainingArguments, [])
    }

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

    func testStopsParsingAtNetworkSubcommand() throws {
        let parsed = try MSLCLIOptionsParser.parseGlobalRuntimeOptions([
            "--instance", "dev", "network", "reconcile"
        ])
        XCTAssertEqual(parsed.instanceName, "dev")
        XCTAssertEqual(parsed.remainingArguments, ["network", "reconcile"])
    }

    func testStopsParsingAtStatusSubcommand() throws {
        let parsed = try MSLCLIOptionsParser.parseGlobalRuntimeOptions([
            "--instance", "dev", "status", "--all"
        ])
        XCTAssertEqual(parsed.instanceName, "dev")
        XCTAssertEqual(parsed.remainingArguments, ["status", "--all"])
    }

    func testStopsParsingAtStopSubcommand() throws {
        let parsed = try MSLCLIOptionsParser.parseGlobalRuntimeOptions([
            "--instance", "dev", "stop", "--all"
        ])
        XCTAssertEqual(parsed.instanceName, "dev")
        XCTAssertEqual(parsed.remainingArguments, ["stop", "--all"])
    }

    func testStopsParsingAtSSHInfoSubcommand() throws {
        let parsed = try MSLCLIOptionsParser.parseGlobalRuntimeOptions([
            "--instance", "dev", "ssh-info", "--format", "json"
        ])
        XCTAssertEqual(parsed.instanceName, "dev")
        XCTAssertEqual(parsed.remainingArguments, ["ssh-info", "--format", "json"])
    }

    func testStopsParsingAtCpSubcommand() throws {
        let parsed = try MSLCLIOptionsParser.parseGlobalRuntimeOptions([
            "--instance", "dev", "cp", "local.txt", "@:/tmp/remote.txt"
        ])
        XCTAssertEqual(parsed.instanceName, "dev")
        XCTAssertEqual(parsed.remainingArguments, ["cp", "local.txt", "@:/tmp/remote.txt"])
    }

    func testRejectsDuplicateInstanceOption() {
        XCTAssertThrowsError(
            try MSLCLIOptionsParser.parseGlobalRuntimeOptions([
                "--instance", "a", "-i", "b"
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

    func testRejectsMissingShortInstanceValue() {
        XCTAssertThrowsError(
            try MSLCLIOptionsParser.parseGlobalRuntimeOptions(["-i"])
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
