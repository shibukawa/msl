import XCTest

final class WaylandHostCoreSourceTests: XCTestCase {
    func testHostCoreComposesPopupSubsurfaceAndTransientSurfaces() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Support/msl-wayland/host-core/src/lib.rs"), encoding: .utf8)

        XCTAssertTrue(source.contains("enum SurfaceRole"))
        XCTAssertTrue(source.contains("PositionerState"))
        XCTAssertTrue(source.contains("SurfaceFrame"))
        XCTAssertTrue(source.contains("compose_frame_for_root"))
        XCTAssertTrue(source.contains("composite_surface_onto"))
        XCTAssertTrue(source.contains("popup_created"))
        XCTAssertTrue(source.contains("popup_configured"))
        XCTAssertTrue(source.contains("popup_committed"))
        XCTAssertTrue(source.contains("subsurface_committed"))
        XCTAssertTrue(source.contains("transient_toplevel_created"))
        XCTAssertTrue(source.contains("remove_child_surface"))
        XCTAssertTrue(source.contains("surface_tree_child_removed"))
        XCTAssertTrue(source.contains("transient_toplevel_removed"))
        XCTAssertTrue(source.contains("composed_frame_emitted"))
        XCTAssertTrue(source.contains("frame_skipped_non_root_surface"))
    }

    func testHostCoreLogsKeyboardDeliveryEdges() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Support/msl-wayland/host-core/src/lib.rs"), encoding: .utf8)

        XCTAssertTrue(source.contains("wl_keyboard_enter_sent"))
        XCTAssertTrue(source.contains("wl_keyboard_key_sent"))
        XCTAssertTrue(source.contains("wl_keyboard_modifiers_sent"))
        XCTAssertTrue(source.contains("wayland_keyboard_event_sent"))
        XCTAssertTrue(source.contains("wayland_keyboard_event_dropped"))
        XCTAssertTrue(source.contains("wayland_keyboard_focus_sent"))
        XCTAssertTrue(source.contains("core_send_keyboard_trace"))
        XCTAssertTrue(source.contains("core_keyboard_debug_snapshot"))
        XCTAssertTrue(source.contains("last_keyboard_trace_id"))
        XCTAssertTrue(source.contains("last_keyboard_drop_reason"))
    }

    func testHostCoreUsesSpecCorrectToplevelMoveResizeOpcodes() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let source = try String(contentsOf: root.appendingPathComponent("Support/msl-wayland/host-core/src/lib.rs"), encoding: .utf8)

        XCTAssertTrue(source.contains(#"("xdg_toplevel", 4) => {"#))
        XCTAssertTrue(source.contains("xdg_toplevel_show_window_menu_requested"))
        XCTAssertTrue(source.contains(#"("xdg_toplevel", 5) => {"#))
        XCTAssertTrue(source.contains("xdg_toplevel_move_requested"))
        XCTAssertTrue(source.contains(#"("xdg_toplevel", 6) => {"#))
        XCTAssertTrue(source.contains("xdg_toplevel_resize_requested"))
    }
}
