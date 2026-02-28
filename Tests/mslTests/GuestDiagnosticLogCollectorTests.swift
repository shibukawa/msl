import XCTest
@testable import mslCore

final class GuestDiagnosticLogCollectorTests: XCTestCase {
    func testCollectorDemuxesChannelsIntoSeparateFiles() throws {
        let ctx = try GuestDiagnosticContext.make()
        defer { ctx.cleanup() }

        let collector = GuestDiagnosticLogCollector(
            paths: ctx.paths,
            instanceName: "dev",
            logger: nil,
            maxBytesPerFile: 1024,
            maxGenerations: 2
        )
        let attachment = try collector.makeSerialAttachment()
        defer {
            collector.stop()
            try? attachment.0.close()
            try? attachment.1.close()
        }

        let payload = """
        [kernel] booting
        [syslog] service started
        [init] ready
        plain-console-line
        """
        try attachment.1.write(contentsOf: Data((payload + "\n").utf8))
        Thread.sleep(forTimeInterval: 0.2)

        let base = ctx.paths.diagnosticLogsDirectory(named: "dev")
        let kernel = try String(contentsOf: base.appendingPathComponent("kernel.log"))
        let syslog = try String(contentsOf: base.appendingPathComponent("syslog.log"))
        let initlog = try String(contentsOf: base.appendingPathComponent("init.log"))
        let console = try String(contentsOf: base.appendingPathComponent("console.log"))

        XCTAssertTrue(kernel.contains("booting"))
        XCTAssertTrue(syslog.contains("service started"))
        XCTAssertTrue(initlog.contains("ready"))
        XCTAssertTrue(console.contains("plain-console-line"))
    }

    func testCollectorRotatesFilesWhenSizeExceeded() throws {
        let ctx = try GuestDiagnosticContext.make()
        defer { ctx.cleanup() }

        let collector = GuestDiagnosticLogCollector(
            paths: ctx.paths,
            instanceName: "rotate",
            logger: nil,
            maxBytesPerFile: 64,
            maxGenerations: 2
        )
        let attachment = try collector.makeSerialAttachment()
        defer {
            collector.stop()
            try? attachment.0.close()
            try? attachment.1.close()
        }

        for idx in 0..<12 {
            let line = "[kernel] line-\(idx)-abcdefghijklmnopqrstuvwxyz0123456789"
            try attachment.1.write(contentsOf: Data((line + "\n").utf8))
        }
        Thread.sleep(forTimeInterval: 0.3)

        let base = ctx.paths.diagnosticLogsDirectory(named: "rotate")
        let rotated = base.appendingPathComponent("kernel.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
    }
}

private struct GuestDiagnosticContext {
    let root: URL
    let paths: MSLPaths

    static func make() throws -> GuestDiagnosticContext {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-guest-diagnostic-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = MSLPaths(homeDirectoryURL: root)
        try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        return GuestDiagnosticContext(root: root, paths: paths)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
