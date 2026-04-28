import XCTest

final class DesktopSourceTests: XCTestCase {
    func testDesktopHidesInternalContainerInstance() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/MSLDesktopApp.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("\"_imagewriter\", \"_container\", \"_podman\""))
    }
}
