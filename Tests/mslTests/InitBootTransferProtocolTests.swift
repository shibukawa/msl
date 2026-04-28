import XCTest
@testable import mslCore

final class InitBootTransferProtocolTests: XCTestCase {
    func testParseHelloLine() {
        let hello = MSLInitBootTransferProtocol.parseHelloLine("MSLB2 HELLO 1 direct-init")
        XCTAssertEqual(hello, .init(version: "1", role: "bootloader", detail: "direct-init"))
    }

    func testParseControlHelloLine() {
        let hello = MSLInitBootTransferProtocol.parseHelloLine("MSLB2 HELLO 1 control")
        XCTAssertEqual(hello, .init(version: "1", role: "control"))
    }

    func testParseSidebandHelloLine() {
        let hello = MSLInitBootTransferProtocol.parseHelloLine("MSLB2 HELLO 1 sideband:sideband")
        XCTAssertEqual(hello, .init(version: "1", role: "sideband", detail: "sideband"))
    }

    func testEncodeDecodeMetadataBlockRoundTrip() throws {
        let encoded = try MSLInitBootTransferProtocol.encodeMetadataBlock(records: [
            .init(targetKind: .bootloader, flags: MSLInitBootTransferProtocol.requiredFlag, entry: "clock.epoch_ms=1775800000123"),
            .init(targetKind: .execEnv, flags: 0, entry: "TZ=Asia/Tokyo"),
            .init(targetKind: .execEnv, flags: 0, entry: "DISPLAY=/tmp/.X11-unix/X0")
        ])
        let decoded = MSLInitBootTransferProtocol.decodeMetadataBlock(encoded)
        XCTAssertEqual(decoded, [
            .init(targetKind: .bootloader, flags: MSLInitBootTransferProtocol.requiredFlag, entry: "clock.epoch_ms=1775800000123"),
            .init(targetKind: .execEnv, flags: 0, entry: "TZ=Asia/Tokyo"),
            .init(targetKind: .execEnv, flags: 0, entry: "DISPLAY=/tmp/.X11-unix/X0")
        ])
    }

    func testDecodeMetadataBlockRejectsUnsupportedVersion() {
        var invalid = Data()
        var version = UInt32(99).littleEndian
        var count = UInt32(0).littleEndian
        withUnsafeBytes(of: &version) { invalid.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { invalid.append(contentsOf: $0) }
        XCTAssertNil(MSLInitBootTransferProtocol.decodeMetadataBlock(invalid))
    }

    func testDecodeMetadataBlockRejectsTruncatedRecord() throws {
        var encoded = try MSLInitBootTransferProtocol.encodeMetadataBlock(records: [
            .init(targetKind: .execEnv, flags: 0, entry: "TZ=Asia/Tokyo")
        ])
        encoded.removeLast()
        XCTAssertNil(MSLInitBootTransferProtocol.decodeMetadataBlock(encoded))
    }

    func testDecodeMetadataBlockRejectsInvalidUTF8() {
        var data = Data()
        var version = UInt32(1).littleEndian
        var count = UInt32(1).littleEndian
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(MSLInitBootTransferProtocol.TargetKind.environment.rawValue)
        data.append(0)
        var reserved = UInt16(0).littleEndian
        var length = UInt32(1).littleEndian
        withUnsafeBytes(of: &reserved) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(0xFF)
        XCTAssertNil(MSLInitBootTransferProtocol.decodeMetadataBlock(data))
    }
}
