import XCTest
@testable import mslCore

final class CopyPathParserTests: XCTestCase {
    func testParsesLocalToRemoteTransfer() throws {
        let transfer = try MSLCopyPathParser.parseTransfer(
            src: "local.txt",
            dest: "@:/tmp/remote.txt",
            recursive: false
        )
        XCTAssertEqual(transfer, MSLCopyTransfer(src: .local("local.txt"), dest: .remote("/tmp/remote.txt")))
    }

    func testParsesRemoteToLocalTransfer() throws {
        let transfer = try MSLCopyPathParser.parseTransfer(
            src: "@:var/log/syslog",
            dest: "./syslog",
            recursive: false
        )
        XCTAssertEqual(transfer, MSLCopyTransfer(src: .remote("var/log/syslog"), dest: .local("./syslog")))
    }

    func testParsesRemoteHomeTransfer() throws {
        let transfer = try MSLCopyPathParser.parseTransfer(
            src: "@:~/notes.txt",
            dest: "./notes.txt",
            recursive: false
        )
        XCTAssertEqual(transfer, MSLCopyTransfer(src: .remote("~/notes.txt"), dest: .local("./notes.txt")))
    }

    func testAllowsLocalTildePath() throws {
        let transfer = try MSLCopyPathParser.parseTransfer(
            src: "~/local.txt",
            dest: "@:/tmp/local.txt",
            recursive: false
        )
        XCTAssertEqual(transfer, MSLCopyTransfer(src: .local("~/local.txt"), dest: .remote("/tmp/local.txt")))
    }

    func testRejectsLocalToLocalTransfer() {
        XCTAssertThrowsError(
            try MSLCopyPathParser.parseTransfer(src: "a", dest: "b", recursive: false)
        ) { error in
            XCTAssertEqual((error as? MSLRuntimeError)?.message, "msl cp requires exactly one VM path using @:/path")
        }
    }

    func testRejectsRemoteToRemoteTransfer() {
        XCTAssertThrowsError(
            try MSLCopyPathParser.parseTransfer(src: "@:/a", dest: "@:/b", recursive: false)
        ) { error in
            XCTAssertEqual((error as? MSLRuntimeError)?.message, "msl cp does not support VM-to-VM copies")
        }
    }

    func testRejectsMalformedRemotePath() {
        XCTAssertThrowsError(
            try MSLCopyPathParser.parseTransfer(src: "@tmp/file", dest: "out", recursive: false)
        ) { error in
            XCTAssertEqual((error as? MSLRuntimeError)?.message, "invalid VM path '@tmp/file'; use @:/path")
        }
    }

    func testRejectsRemoteOtherUserHomePath() {
        XCTAssertThrowsError(
            try MSLCopyPathParser.parseTransfer(src: "@:~alice/file", dest: "out", recursive: false)
        ) { error in
            XCTAssertEqual((error as? MSLRuntimeError)?.message, "unsupported VM path '@:~alice/file'; only @:~ and @:~/... are supported")
        }
    }

    func testRejectsLocalOtherUserHomePath() {
        XCTAssertThrowsError(
            try MSLCopyPathParser.parseTransfer(src: "~alice/file", dest: "@:/tmp/out", recursive: false)
        ) { error in
            XCTAssertEqual((error as? MSLRuntimeError)?.message, "unsupported local path '~alice/file'; only ~ and ~/... are supported")
        }
    }

    func testRejectsDirectorySourceWithoutRecursiveFlag() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-copy-path-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousCwd = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(root.path))
        defer {
            _ = FileManager.default.changeCurrentDirectoryPath(previousCwd)
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(atPath: "dir", withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try MSLCopyPathParser.parseTransfer(src: "dir", dest: "@:/tmp/dir", recursive: false)
        ) { error in
            XCTAssertEqual((error as? MSLRuntimeError)?.message, "omitting directory 'dir'; use -r to copy directories")
        }
    }
}
