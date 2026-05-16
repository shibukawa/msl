import XCTest
@testable import mslCore

final class WaylandModelsTests: XCTestCase {
    func testManagedGUIEnvironmentSetsWaylandDefaults() {
        let env = managedGUIEnvironment(displayName: "wayland-test", sessionID: "gui-1", port: 38123)
        XCTAssertEqual(env["WAYLAND_DISPLAY"], "wayland-test")
        XCTAssertEqual(env["GDK_BACKEND"], "wayland")
        XCTAssertEqual(env["QT_QPA_PLATFORM"], "wayland")
        XCTAssertEqual(env["XDG_SESSION_TYPE"], "wayland")
        XCTAssertEqual(env["XDG_RUNTIME_DIR"], "/tmp")
        XCTAssertEqual(env["MSL_GUI_SESSION_ID"], "gui-1")
        XCTAssertEqual(env["MSL_DISPLAY_VSOCK_PORT"], "38123")
        XCTAssertNil(env["MSL_GUEST_WAYLAND_PROXY_BIN"])
    }

    func testDefaultWaylandEnvironmentSetsStandardExecutionDefaults() {
        let env = defaultWaylandEnvironment()
        XCTAssertEqual(env["WAYLAND_DISPLAY"], "wayland-0")
        XCTAssertEqual(env["MSL_WAYLAND_DISPLAY"], "wayland-0")
        XCTAssertEqual(env["GDK_BACKEND"], "wayland")
        XCTAssertEqual(env["QT_QPA_PLATFORM"], "wayland")
        XCTAssertEqual(env["SDL_VIDEODRIVER"], "wayland")
        XCTAssertEqual(env["MOZ_ENABLE_WAYLAND"], "1")
        XCTAssertEqual(env["XDG_SESSION_TYPE"], "wayland")
        XCTAssertEqual(env["XDG_RUNTIME_DIR"], "/tmp")
        XCTAssertNil(env["MSL_GUI_SESSION_ID"])
        XCTAssertNil(env["MSL_DISPLAY_VSOCK_PORT"])
    }

    func testWaylandProfileScriptSetsGuestShellDefaults() {
        let script = mslWaylandProfileScript()
        XCTAssertTrue(script.contains("WAYLAND_DISPLAY=\"${WAYLAND_DISPLAY:-wayland-0}\""))
        XCTAssertTrue(script.contains("GDK_BACKEND=\"${GDK_BACKEND:-wayland}\""))
        XCTAssertTrue(script.contains("QT_QPA_PLATFORM=\"${QT_QPA_PLATFORM:-wayland}\""))
        XCTAssertTrue(script.contains("XDG_RUNTIME_DIR=\"${XDG_RUNTIME_DIR:-/tmp}\""))
        XCTAssertFalse(script.contains("MSL_GUEST_WAYLAND_PROXY_BIN"))
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

    func testSharedFrameEnvelopeRoundTrip() throws {
        let sharedFrame = RuntimeGUISharedFrame(
            sessionId: "session-a",
            shmName: "/msl-wl-test",
            width: 2,
            height: 2,
            stride: 8,
            pixelFormat: .bgra8888,
            damageRects: [RuntimeGUIFrameDamageRect(x: 0, y: 0, width: 1, height: 1)],
            slot: 1,
            slotOffset: 4096,
            slotSize: 32,
            mappedSize: 8192,
            generation: 7,
            layoutGeneration: 2,
            epochMs: 123
        )
        let envelope = RuntimeGUIDisplayEnvelope(kind: .frame, sharedFrame: sharedFrame)
        let decoded = try RuntimeGUIDisplayEnvelope.decode(envelope.encoded())

        XCTAssertEqual(decoded.sharedFrame, sharedFrame)
        XCTAssertNil(decoded.frame?.dataBase64)
    }

    func testIMEStateRoundTripKeepsCompositionRanges() throws {
        let state = RuntimeGUIIMEState(
            sessionId: "session-a",
            enabled: true,
            surroundingText: "あいう",
            cursorUTF16Offset: 2,
            anchorUTF16Offset: 2,
            preedit: "変換",
            markedRangeUTF16: RuntimeGUITextRange(location: 1, length: 2),
            preeditSelectionUTF16: RuntimeGUITextRange(location: 1, length: 0),
            replacementRangeUTF16: RuntimeGUITextRange(location: 1, length: 0),
            preeditCursorBeginUTF16: 1,
            preeditCursorEndUTF16: 1,
            compositionActive: true,
            cursorRect: RuntimeGUICursorRect(x: 10, y: 20, width: 1, height: 18)
        )
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RuntimeGUIIMEState.self, from: encoded)

        XCTAssertEqual(decoded, state)
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
