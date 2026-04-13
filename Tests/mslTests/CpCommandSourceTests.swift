import XCTest

final class CpCommandSourceTests: XCTestCase {
    func testCpCommandIsRegisteredAndDocumentsRemotePaths() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/msl/main.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("CpCommand.self"))
        XCTAssertTrue(source.contains("commandName: \"cp\""))
        XCTAssertTrue(source.contains("Use @:/path to reference the VM side."))
        XCTAssertTrue(source.contains("Copy directories recursively."))
        XCTAssertTrue(source.contains("manager.runCopy("))
    }
}
