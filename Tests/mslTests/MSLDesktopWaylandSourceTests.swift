import XCTest

final class MSLDesktopWaylandSourceTests: XCTestCase {
    func testDesktopSubscribesToWaylandFrameEventsAndFetchesLatestFrame() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/MSLDesktopApp.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("DesktopDaemonEventSubscription"))
        XCTAssertTrue(source.contains(#""topics":["gui_frame","gui_cursor","gui_ime","gui_session","gui_window_event"]"#))
        XCTAssertTrue(source.contains("handleGUIFrameEvent"))
        XCTAssertTrue(source.contains("handleGUICursorEvent"))
        XCTAssertTrue(source.contains("handleGUIIMEEvent"))
        XCTAssertTrue(source.contains("handleGUIWindowEvent"))
        XCTAssertTrue(source.contains("postWaylandSharedFrame"))
        XCTAssertTrue(source.contains("waylandCursor"))
        XCTAssertTrue(source.contains("waylandWindowEvent"))
        XCTAssertTrue(source.contains("wayland_ime_event_received"))
        XCTAssertTrue(source.contains("op: \"gui_frame_latest\""))
        XCTAssertTrue(source.contains("frameSnapshotPath"))
        XCTAssertTrue(source.contains("sharedFrame(from:"))
        XCTAssertTrue(source.contains("postWaylandSharedFrame"))
        XCTAssertTrue(source.contains("loadWaylandFrameSnapshot"))
        XCTAssertTrue(source.contains("wayland_frame_event_received"))
        XCTAssertTrue(source.contains("wayland_frame_fetched"))
        XCTAssertTrue(source.contains(#""source": source"#))
    }

    func testWaylandWindowHostUsesMetalPathForFrames() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/WaylandWindowHost.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("CAMetalLayer"))
        XCTAssertTrue(source.contains("metalLayer.isOpaque = false"))
        XCTAssertTrue(source.contains("NSColor.clear.cgColor"))
        XCTAssertTrue(source.contains("makeCommandQueue"))
        XCTAssertTrue(source.contains("drawMetalFrame"))
        XCTAssertTrue(source.contains("drawMetalSharedFrame"))
        XCTAssertTrue(source.contains("msl_shm_open"))
        XCTAssertTrue(source.contains("replace("))
        XCTAssertTrue(source.contains("makeBlitCommandEncoder"))
        XCTAssertTrue(source.contains("wayland_metal_drawn"))
        XCTAssertTrue(source.contains("shouldUploadFullFrame"))
        XCTAssertTrue(source.contains("source=%@"))
        XCTAssertFalse(source.contains("frameLayer.contents = image"))
    }

    func testWaylandWindowActivationIsForegrounded() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/WaylandWindowHost.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("func bringToFront()"))
        XCTAssertTrue(source.contains("NSApp.activate(ignoringOtherApps: true)"))
        XCTAssertTrue(source.contains("makeKeyAndOrderFront(nil)"))
        XCTAssertTrue(source.contains("orderFrontRegardless()"))
    }

    func testWaylandWindowIsBorderlessAndRoutesInput() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/WaylandWindowHost.swift"), encoding: .utf8)
        let bridge = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/WaylandCoreBridge.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("styleMask: [.borderless]"))
        XCTAssertTrue(source.contains("private final class WaylandHostWindow: NSWindow"))
        XCTAssertTrue(source.contains("override var canBecomeKey: Bool { true }"))
        XCTAssertTrue(source.contains("override var canBecomeMain: Bool { true }"))
        XCTAssertTrue(source.contains("override func sendEvent(_ event: NSEvent)"))
        XCTAssertTrue(source.contains("wayland_host_window_key_event"))
        XCTAssertTrue(source.contains("wayland_host_window_direct_key_fallback"))
        XCTAssertTrue(source.contains("window = WaylandHostWindow("))
        XCTAssertTrue(source.contains("window.isOpaque = false"))
        XCTAssertTrue(source.contains("window.backgroundColor = .clear"))
        XCTAssertTrue(source.contains(#"op: "gui_request_close""#))
        XCTAssertTrue(source.contains("return false"))
        XCTAssertTrue(source.contains("resizeEdge(for:"))
        XCTAssertTrue(source.contains("waylandRuntimeControlRequest"))
        XCTAssertTrue(source.contains(#"op: "gui_send_pointer""#))
        XCTAssertTrue(source.contains(#"op: "gui_send_keyboard""#))
        XCTAssertTrue(source.contains(#"op: "gui_send_focus""#))
        XCTAssertTrue(source.contains(#"op: "gui_set_geometry""#))
        XCTAssertTrue(source.contains(#"op: "gui_send_ime_state""#))
        XCTAssertTrue(source.contains("override func flagsChanged"))
        XCTAssertTrue(source.contains("override func performKeyEquivalent"))
        XCTAssertTrue(source.contains("wayland_key_down"))
        XCTAssertTrue(source.contains("wayland_key_up"))
        XCTAssertTrue(source.contains("wayland_flags_changed"))
        XCTAssertTrue(source.contains("wayland_key_unmapped"))
        XCTAssertTrue(source.contains("wayland_perform_key_equivalent"))
        XCTAssertTrue(source.contains("keyboardTraceID(kind:"))
        XCTAssertTrue(source.contains("appendWaylandKeyboardLog"))
        XCTAssertTrue(source.contains("wayland-keyboard.log"))
        XCTAssertTrue(source.contains("claimKeyboardFocus(reason:"))
        XCTAssertTrue(source.contains("override func becomeFirstResponder()"))
        XCTAssertTrue(source.contains("override func resignFirstResponder()"))
        XCTAssertTrue(source.contains("handleWindowFallbackKeyEvent"))
        XCTAssertTrue(source.contains("handleWaylandWindowEvent"))
        XCTAssertTrue(source.contains("moveStartWindowFrame"))
        XCTAssertTrue(source.contains("wayland_move_session_started"))
        XCTAssertTrue(source.contains("wayland_move_session_updated"))
        XCTAssertTrue(source.contains("wayland_move_session_finished"))
        XCTAssertTrue(source.contains("interpretKeyEvents([event])"))
        XCTAssertTrue(source.contains("textInputActive"))
        XCTAssertTrue(source.contains("shouldRouteToTextInput"))
        XCTAssertTrue(source.contains("wayland_ime_state_sent"))
        XCTAssertTrue(source.contains("42: 43, 43: 51"))
        XCTAssertTrue(source.contains("45: 49, 46: 50, 47: 52"))
        XCTAssertTrue(bridge.contains("core_send_pointer"))
        XCTAssertTrue(bridge.contains("core_send_keyboard"))
        XCTAssertTrue(bridge.contains("core_send_focus"))
        XCTAssertTrue(bridge.contains("core_request_toplevel_close"))
    }

    func testWaylandWindowAvoidsFrameDrivenGeometryLoop() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/WaylandWindowHost.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("hasAppliedInitialFrameSize"))
        XCTAssertTrue(source.contains("applyInitialFrameSize(width:"))
        XCTAssertTrue(source.contains("sendGeometryIfNeeded"))
        XCTAssertTrue(source.contains("lastSentGeometry"))
        XCTAssertFalse(source.contains("override func layout() {\n        super.layout()\n        statusLabel.frame = NSRect(x: 20, y: bounds.height - 56, width: bounds.width - 40, height: 24)\n        imeLabel.frame = NSRect(x: 20, y: bounds.height - 88, width: bounds.width - 40, height: 20)\n        layer?.frame = bounds\n        postWaylandRuntimeControl"))
    }

    func testQuitDesktopBringsAlertForward() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MSLDesktop/MSLDesktopApp.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("bringDashboardToFront()"))
        XCTAssertTrue(source.contains("alert.window.level = .modalPanel"))
        XCTAssertTrue(source.contains("window.orderFrontRegardless()"))
        XCTAssertTrue(source.contains("forceQuitRequested"))
        XCTAssertTrue(source.contains("setDesktopQuitHandler"))
    }
}
