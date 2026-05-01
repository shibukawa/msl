import XCTest
@testable import mslCore

final class WaylandModelsTests: XCTestCase {
    func testManagedGUIEnvironmentSetsWaylandDefaults() {
        let env = managedGUIEnvironment(displayName: "wayland-test", sessionID: "gui-1", port: 38123)
        XCTAssertEqual(env["WAYLAND_DISPLAY"], "wayland-test")
        XCTAssertEqual(env["XDG_SESSION_TYPE"], "wayland")
        XCTAssertEqual(env["MSL_GUI_SESSION_ID"], "gui-1")
        XCTAssertEqual(env["MSL_DISPLAY_VSOCK_PORT"], "38123")
    }

    func testDisplayEnvelopeRoundTrip() throws {
        let session = RuntimeGUISession(
            id: "gui-1",
            instanceName: "ubuntu",
            sessionId: "session-1",
            procId: "proc-1",
            title: "gedit",
            command: ["gedit"],
            state: .running,
            display: RuntimeGUIDisplayDescriptor(displayName: "wayland-1", port: 38001),
            startedAtEpochMs: 1,
            lastUpdatedEpochMs: 2
        )
        let envelope = RuntimeGUIDisplayEnvelope(kind: .hello, session: session, meta: ["version": "1"])
        let decoded = try RuntimeGUIDisplayEnvelope.decode(envelope.encoded())
        XCTAssertEqual(decoded.kind, .hello)
        XCTAssertEqual(decoded.session?.id, "gui-1")
        XCTAssertEqual(decoded.meta?["version"], "1")
    }

    func testApplyDamageRectsUpdatesOnlyTargetRegion() throws {
        let source = Data([1, 1, 1, 1, 9, 9, 9, 9])
        let frame = RuntimeGUIFrame(
            sessionId: "gui-1",
            width: 2,
            height: 1,
            stride: 8,
            pixelFormat: .bgra8888,
            damageRects: [RuntimeGUIFrameDamageRect(x: 1, y: 0, width: 1, height: 1)],
            dataBase64: source.base64EncodedString(),
            epochMs: 1,
            rawData: source
        )
        var destination = Data([0, 0, 0, 0, 2, 2, 2, 2])
        try applyDamageRects(from: frame, to: &destination)
        XCTAssertEqual(destination, Data([0, 0, 0, 0, 9, 9, 9, 9]))
    }
}
