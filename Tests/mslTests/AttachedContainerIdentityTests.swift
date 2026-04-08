import XCTest
@testable import mslCore

final class AttachedContainerIdentityTests: XCTestCase {
    func testVmIDNormalizesSimpleInstanceName() {
        XCTAssertEqual(AttachedContainerIdentity.vmID(forInstance: "ubuntu"), "msl-ubuntu")
    }

    func testVmIDNormalizesUppercaseAndSymbols() {
        XCTAssertEqual(AttachedContainerIdentity.vmID(forInstance: "Dev Box@2026"), "msl-dev-box-2026")
    }

    func testVmIDFallsBackWhenEmptyAfterNormalization() {
        XCTAssertEqual(AttachedContainerIdentity.vmID(forInstance: "___"), "msl-default")
    }

    func testSocketPathIsScopedByInstance() {
        let a = AttachedContainerIdentity.socketPath(forInstance: "ubuntu")
        let b = AttachedContainerIdentity.socketPath(forInstance: "devbox")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.contains("/Library/Application Support/msl/runtime/"))
        XCTAssertTrue(a.contains("/a-"))
        XCTAssertTrue(a.hasSuffix(".sock"))
        XCTAssertLessThan(a.count, 104)
    }

    func testContainerIDIsStableHexString() {
        let a = AttachedContainerIdentity.containerID(forInstance: "ubuntu")
        let b = AttachedContainerIdentity.containerID(forInstance: "ubuntu")
        let c = AttachedContainerIdentity.containerID(forInstance: "devbox")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.count, 64)
        XCTAssertNotNil(UInt64(String(a.prefix(16)), radix: 16))
    }
}
