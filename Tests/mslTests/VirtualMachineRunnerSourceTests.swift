import XCTest

final class VirtualMachineRunnerSourceTests: XCTestCase {
    func testBootloaderTransferSendsTimezoneAsExecEnv() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/mslCore/VirtualMachineRunner.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("targetKind: .execEnv"))
        XCTAssertTrue(source.contains("entry: \"TZ=\\(hostTimeZoneID)\""))
        XCTAssertFalse(source.contains("targetKind: .environment,\n                flags: 0,\n                entry: \"TZ=\\(hostTimeZoneID)\""))
    }
}
