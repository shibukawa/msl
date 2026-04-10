import XCTest

final class ListCommandSourceTests: XCTestCase {
    func testListCommandExposesReservedInstanceFlag() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/msl/main.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains(".customLong(\"include-reserved\")"))
        XCTAssertTrue(source.contains("Include reserved internal instances."))
        XCTAssertTrue(source.contains("listInstalledInstances(includeReserved: all)"))
    }
}
