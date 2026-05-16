import AppKit
import Darwin
import Metal
import QuartzCore
import mslCore

@_silgen_name("shm_open")
private func msl_shm_open(_ name: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32

private let waylandSharedFrameGenerationOffset = 48

extension Notification.Name {
    static let waylandRuntimeControlRequest = Notification.Name("MSLWaylandRuntimeControlRequest")
    static let waylandCursor = Notification.Name("MSLWaylandCursor")
    static let waylandWindowEvent = Notification.Name("MSLWaylandWindowEvent")
}

private func appendWaylandKeyboardLog(_ message: String) {
    NSLog("%@", message)
    let url = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/msl/runtime/logs/wayland-keyboard.log", isDirectory: false)
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        if let data = line.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
    } catch {
        NSLog("wayland_keyboard_log_write_failed error=%@", String(describing: error))
    }
}

private final class WaylandHostWindow: NSWindow {
    weak var waylandHostView: WaylandWindowHostView?
    var guiSessionID: String = ""

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            appendWaylandKeyboardLog(String(
                format: "wayland_host_window_key_event guiSessionId=%@ type=%@ keyWindow=%@ firstResponder=%@ appkitKeyCode=%u",
                guiSessionID,
                String(describing: event.type),
                String(isKeyWindow),
                String(describing: firstResponder),
                event.keyCode
            ))
            if let hostView = waylandHostView, firstResponder !== hostView {
                let restored = makeFirstResponder(hostView)
                appendWaylandKeyboardLog(String(
                    format: "wayland_host_window_restore_first_responder guiSessionId=%@ restored=%@ firstResponder=%@",
                    guiSessionID,
                    String(restored),
                    String(describing: firstResponder)
                ))
            }
            let before = firstResponder
            super.sendEvent(event)
            if firstResponder === before,
               let hostView = waylandHostView,
               before !== hostView {
                appendWaylandKeyboardLog(String(
                    format: "wayland_host_window_direct_key_fallback guiSessionId=%@ type=%@ appkitKeyCode=%u",
                    guiSessionID,
                    String(describing: event.type),
                    event.keyCode
                ))
                hostView.handleWindowFallbackKeyEvent(event)
            }
        default:
            super.sendEvent(event)
        }
    }
}

private final class WaylandSharedFrameMapping {
    let shmName: String
    let layoutGeneration: UInt64
    let size: Int
    let pointer: UnsafeMutableRawPointer

    init(shmName: String, layoutGeneration: UInt64, size: Int) throws {
        let fd = shmName.withCString { name in
            msl_shm_open(name, O_RDONLY, 0)
        }
        guard fd >= 0 else {
            throw MSLRuntimeError("shm_open failed for \(shmName)")
        }
        defer { close(fd) }
        let pointer = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0)
        guard pointer != MAP_FAILED, let pointer else {
            throw MSLRuntimeError("mmap failed for \(shmName)")
        }
        self.shmName = shmName
        self.layoutGeneration = layoutGeneration
        self.size = size
        self.pointer = pointer
    }

    deinit {
        munmap(pointer, size)
    }
}

@MainActor
final class GUIWindowManager {
    private var controllers: [String: GUIWindowController] = [:]

    func sync(sessions: [RuntimeGUISession]) {
        WaylandCoreBridge.shared.startIfNeeded()
        let liveIDs = Set(sessions.filter { $0.state != .stopped }.map(\.id))

        for session in sessions where session.state != .stopped {
            if let controller = controllers[session.id] {
                controller.update(session: session)
            } else {
                let controller = GUIWindowController(session: session)
                controllers[session.id] = controller
                controller.bringToFront()
            }
            WaylandCoreBridge.shared.attach(session: session)
        }

        for (id, controller) in controllers where !liveIDs.contains(id) {
            WaylandCoreBridge.shared.detach(sessionID: id)
            controller.close()
            controllers.removeValue(forKey: id)
        }
    }
}

@MainActor
final class GUIWindowController: NSWindowController, NSWindowDelegate {
    private let hostViewController: WaylandWindowHostViewController
    private var guiSession: RuntimeGUISession

    init(session: RuntimeGUISession) {
        self.guiSession = session
        self.hostViewController = WaylandWindowHostViewController(session: session)
        let rect = NSRect(x: 0, y: 0, width: CGFloat(session.display.width), height: CGFloat(session.display.height))
        let window = WaylandHostWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.guiSessionID = session.id
        window.waylandHostView = hostViewController.hostView
        window.title = session.title
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.contentViewController = hostViewController
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(session: RuntimeGUISession) {
        guiSession = session
        (window as? WaylandHostWindow)?.guiSessionID = session.id
        (window as? WaylandHostWindow)?.waylandHostView = hostViewController.hostView
        window?.title = session.title
        hostViewController.update(session: session)
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        hostViewController.claimKeyboardFocus(reason: "bringToFront")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        postWaylandRuntimeControl(op: "gui_request_close", session: guiSession)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        hostViewController.claimKeyboardFocus(reason: "windowDidBecomeKey")
        postWaylandRuntimeControl(op: "gui_send_focus", session: guiSession, argv: ["true"])
    }

    func windowDidResignKey(_ notification: Notification) {
        postWaylandRuntimeControl(op: "gui_send_focus", session: guiSession, argv: ["false"])
    }
}

private func postWaylandRuntimeControl(
    op: String,
    session: RuntimeGUISession,
    argv: [String] = [],
    imeState: RuntimeGUIIMEState? = nil
) {
    var userInfo: [String: Any] = [
        "op": op,
        "instanceName": session.instanceName,
        "guiSessionId": session.id,
        "argv": argv
    ]
    if let imeState {
        userInfo["imeState"] = imeState
    }
    NotificationCenter.default.post(name: .waylandRuntimeControlRequest, object: nil, userInfo: userInfo)
}

@MainActor
final class WaylandWindowHostViewController: NSViewController {
    let hostView: WaylandWindowHostView

    init(session: RuntimeGUISession) {
        self.hostView = WaylandWindowHostView(session: session)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = hostView
    }

    func update(session: RuntimeGUISession) {
        hostView.update(session: session)
    }

    func claimKeyboardFocus(reason: String) {
        hostView.claimKeyboardFocus(reason: reason)
    }
}

final class WaylandWindowHostView: NSView, NSTextInputClient {
    private enum ResizeEdge {
        case left
        case right
        case top
        case bottom
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    private let device = MTLCreateSystemDefaultDevice()
    private let commandQueue: MTLCommandQueue?
    private let statusLabel = NSTextField(labelWithString: "")
    private let imeLabel = NSTextField(labelWithString: "")
    private var guiSession: RuntimeGUISession
    private var surroundingText = ""
    private var textInputActive = false
    private var markedTextValue = NSAttributedString(string: "")
    private var selectedTextRange = NSRange(location: 0, length: 0)
    private var markedTextRange = NSRange(location: NSNotFound, length: 0)
    private var preeditSelectionRange = NSRange(location: 0, length: 0)
    private var lastReplacementRange = NSRange(location: NSNotFound, length: 0)
    private var cursorRect = RuntimeGUICursorRect(x: 20, y: 20, width: 1, height: 20)
    private var backingBuffer = Data()
    private var frameTexture: MTLTexture?
    private var frameTextureSize = MTLSize(width: 0, height: 0, depth: 1)
    private var hasDrawnFrame = false
    private var sharedFrameMapping: WaylandSharedFrameMapping?
    private var notificationTokens: [NSObjectProtocol] = []
    private var trackingArea: NSTrackingArea?
    private var resizeEdge: ResizeEdge?
    private var resizeStartWindowFrame: NSRect = .zero
    private var resizeStartScreenPoint: NSPoint = .zero
    private var moveStartWindowFrame: NSRect?
    private var moveStartScreenPoint: NSPoint?
    private var hasAppliedInitialFrameSize = false
    private var suppressGeometryUpdate = false
    private var lastSentGeometry: NSSize?
    private var currentWaylandCursor: NSCursor?
    private var lastMouseDownEvent: NSEvent?
    private var lastMouseDownAt: TimeInterval = 0

    init(session: RuntimeGUISession) {
        self.guiSession = session
        self.commandQueue = device?.makeCommandQueue()
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: CGFloat(session.display.width),
            height: CGFloat(session.display.height)
        ))
        wantsLayer = true
        layer = makeBackingLayer()
        setupLabels()
        setupNotifications()
        update(session: session)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        return metalLayer
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        appendWaylandKeyboardLog(String(
            format: "wayland_view_become_first_responder guiSessionId=%@ window=%@",
            guiSession.id,
            String(describing: window)
        ))
        return true
    }

    override func resignFirstResponder() -> Bool {
        appendWaylandKeyboardLog(String(
            format: "wayland_view_resign_first_responder guiSessionId=%@ window=%@",
            guiSession.id,
            String(describing: window)
        ))
        return true
    }

    func claimKeyboardFocus(reason: String) {
        let restored = window?.makeFirstResponder(self) ?? false
        appendWaylandKeyboardLog(String(
            format: "wayland_claim_keyboard_focus guiSessionId=%@ reason=%@ restored=%@ keyWindow=%@ firstResponder=%@",
            guiSession.id,
            reason,
            String(restored),
            String(window?.isKeyWindow == true),
            String(describing: window?.firstResponder)
        ))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimKeyboardFocus(reason: "viewDidMoveToWindow")
        window?.acceptsMouseMovedEvents = true
        postWaylandRuntimeControl(
            op: "gui_send_focus",
            session: guiSession,
            argv: [window?.isKeyWindow == true ? "true" : "false"]
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func layout() {
        super.layout()
        statusLabel.frame = NSRect(x: 20, y: bounds.height - 56, width: bounds.width - 40, height: 24)
        imeLabel.frame = NSRect(x: 20, y: bounds.height - 88, width: bounds.width - 40, height: 20)
        layer?.frame = bounds
    }

    func update(session: RuntimeGUISession) {
        guiSession = session
        statusLabel.stringValue = [
            session.instanceName,
            session.state.rawValue,
            session.display.displayName + ":\(session.display.port)"
        ].joined(separator: "  ")
        imeLabel.stringValue = markedTextValue.string.isEmpty ? "IME: inactive" : "IME: \(markedTextValue.string)"
        needsLayout = true
    }

    private func setupLabels() {
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        imeLabel.textColor = .secondaryLabelColor
        imeLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        addSubview(statusLabel)
        addSubview(imeLabel)
    }

    private func sendPointer(
        _ event: NSEvent,
        kind: Int32,
        button: UInt32 = 0,
        axisX: Double = 0,
        axisY: Double = 0
    ) {
        let point = waylandPoint(for: event)
        postWaylandRuntimeControl(
            op: "gui_send_pointer",
            session: guiSession,
            argv: [
                String(kind),
                String(Double(point.x)),
                String(Double(point.y)),
                String(button),
                String(axisX),
                String(axisY),
                String(waylandModifiers(from: event)),
                String(WaylandWindowHostView.timestampMs())
            ]
        )
    }

    private func waylandPoint(for event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        let x = max(0, min(bounds.width, local.x))
        let y = max(0, min(bounds.height, bounds.height - local.y))
        return CGPoint(x: x, y: y)
    }

    private func resizeEdge(for point: NSPoint) -> ResizeEdge? {
        let margin: CGFloat = 6
        let left = point.x <= margin
        let right = point.x >= bounds.width - margin
        let bottom = point.y <= margin
        let top = point.y >= bounds.height - margin
        switch (left, right, top, bottom) {
        case (true, false, true, false): return .topLeft
        case (false, true, true, false): return .topRight
        case (true, false, false, true): return .bottomLeft
        case (false, true, false, true): return .bottomRight
        case (true, false, false, false): return .left
        case (false, true, false, false): return .right
        case (false, false, true, false): return .top
        case (false, false, false, true): return .bottom
        default: return nil
        }
    }

    private func resizeEdge(fromXDGEdge edge: UInt32) -> ResizeEdge? {
        switch edge {
        case 1: return .top
        case 2: return .bottom
        case 4: return .left
        case 5: return .topLeft
        case 6: return .bottomLeft
        case 8: return .right
        case 9: return .topRight
        case 10: return .bottomRight
        default: return nil
        }
    }

    private func resizeWindow(with event: NSEvent) {
        guard let window, let resizeEdge else { return }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        let dx = screenPoint.x - resizeStartScreenPoint.x
        let dy = screenPoint.y - resizeStartScreenPoint.y
        var frame = resizeStartWindowFrame
        let minWidth: CGFloat = 320
        let minHeight: CGFloat = 240

        func applyLeft() {
            let proposedWidth = frame.width - dx
            if proposedWidth >= minWidth {
                frame.origin.x += dx
                frame.size.width = proposedWidth
            }
        }
        func applyRight() {
            frame.size.width = max(minWidth, frame.width + dx)
        }
        func applyBottom() {
            let proposedHeight = frame.height - dy
            if proposedHeight >= minHeight {
                frame.origin.y += dy
                frame.size.height = proposedHeight
            }
        }
        func applyTop() {
            frame.size.height = max(minHeight, frame.height + dy)
        }

        switch resizeEdge {
        case .left: applyLeft()
        case .right: applyRight()
        case .top: applyTop()
        case .bottom: applyBottom()
        case .topLeft:
            applyTop()
            applyLeft()
        case .topRight:
            applyTop()
            applyRight()
        case .bottomLeft:
            applyBottom()
            applyLeft()
        case .bottomRight:
            applyBottom()
            applyRight()
        }
        window.setFrame(frame, display: true)
    }

    private func linuxEvdevKeycode(for event: NSEvent) -> UInt32? {
        let map: [UInt16: UInt32] = [
            0: 30, 1: 31, 2: 32, 3: 33, 4: 35, 5: 34, 6: 44, 7: 45,
            8: 46, 9: 47, 11: 48, 12: 16, 13: 17, 14: 18, 15: 19,
            16: 21, 17: 20, 18: 2, 19: 3, 20: 4, 21: 5, 22: 7,
            23: 6, 24: 13, 25: 10, 26: 8, 27: 12, 28: 9, 29: 11,
            30: 27, 31: 24, 32: 22, 33: 26, 34: 23, 35: 25, 36: 28,
            37: 38, 38: 36, 39: 40, 40: 37, 41: 39, 42: 43, 43: 51,
            44: 53, 45: 49, 46: 50, 47: 52, 48: 15, 49: 57, 50: 41,
            51: 14, 53: 1, 54: 125, 55: 56, 56: 42, 57: 58, 58: 56,
            59: 29, 60: 54, 61: 184, 62: 97, 63: 125, 64: 100, 65: 83,
            67: 55, 69: 78, 71: 69, 75: 181, 76: 96, 78: 74, 81: 98,
            82: 82, 83: 79, 84: 80, 85: 81, 86: 75, 87: 76, 88: 77,
            89: 71, 91: 72, 92: 73, 96: 63, 97: 64, 98: 65, 99: 61,
            100: 66, 101: 67, 103: 87, 105: 183, 106: 99, 107: 70,
            109: 88, 111: 105, 113: 110, 114: 102, 115: 104, 116: 111,
            117: 107, 118: 109, 119: 106, 120: 103, 121: 108, 122: 59,
            123: 105, 124: 106, 125: 108, 126: 103
        ]
        return map[event.keyCode]
    }

    private func waylandModifiers(from event: NSEvent) -> UInt32 {
        var value: UInt32 = 0
        if event.modifierFlags.contains(.shift) { value |= 1 << 0 }
        if event.modifierFlags.contains(.control) { value |= 1 << 1 }
        if event.modifierFlags.contains(.option) { value |= 1 << 2 }
        if event.modifierFlags.contains(.command) { value |= 1 << 3 }
        return value
    }

    private static func timestampMs() -> UInt32 {
        UInt32(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970 * 1000))
    }

    override func mouseEntered(with event: NSEvent) {
        currentWaylandCursor?.set()
        sendPointer(event, kind: 0)
    }

    override func mouseExited(with event: NSEvent) {
        sendPointer(event, kind: 4)
    }

    override func mouseMoved(with event: NSEvent) {
        currentWaylandCursor?.set()
        sendPointer(event, kind: 0)
    }

    override func mouseDown(with event: NSEvent) {
        claimKeyboardFocus(reason: "mouseDown")
        lastMouseDownEvent = event
        lastMouseDownAt = Date().timeIntervalSince1970
        postWaylandRuntimeControl(op: "gui_send_focus", session: guiSession, argv: ["true"])
        if let edge = resizeEdge(for: convert(event.locationInWindow, from: nil)) {
            resizeEdge = edge
            resizeStartWindowFrame = window?.frame ?? .zero
            resizeStartScreenPoint = event.locationInWindow
            if let window {
                resizeStartScreenPoint = window.convertPoint(toScreen: resizeStartScreenPoint)
            }
            return
        }
        sendPointer(event, kind: 1, button: 0x110)
    }

    override func mouseDragged(with event: NSEvent) {
        if moveStartWindowFrame != nil {
            moveWindow(with: event)
            return
        }
        if resizeEdge != nil {
            resizeWindow(with: event)
            return
        }
        sendPointer(event, kind: 0)
    }

    override func mouseUp(with event: NSEvent) {
        if moveStartWindowFrame != nil {
            moveStartWindowFrame = nil
            moveStartScreenPoint = nil
            NSLog("wayland_move_session_finished guiSessionId=%@", guiSession.id)
            sendPointer(event, kind: 2, button: 0x110)
            return
        }
        if resizeEdge != nil {
            resizeEdge = nil
            if let window {
                sendGeometryIfNeeded(window.contentLayoutRect.size)
            }
            return
        }
        sendPointer(event, kind: 2, button: 0x110)
    }

    override func rightMouseDown(with event: NSEvent) {
        claimKeyboardFocus(reason: "rightMouseDown")
        lastMouseDownEvent = event
        lastMouseDownAt = Date().timeIntervalSince1970
        sendPointer(event, kind: 1, button: 0x111)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendPointer(event, kind: 2, button: 0x111)
    }

    override func otherMouseDown(with event: NSEvent) {
        claimKeyboardFocus(reason: "otherMouseDown")
        lastMouseDownEvent = event
        lastMouseDownAt = Date().timeIntervalSince1970
        sendPointer(event, kind: 1, button: UInt32(0x110 + max(0, event.buttonNumber)))
    }

    override func otherMouseUp(with event: NSEvent) {
        sendPointer(event, kind: 2, button: UInt32(0x110 + max(0, event.buttonNumber)))
    }

    override func scrollWheel(with event: NSEvent) {
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        sendPointer(event, kind: 3, axisX: -event.scrollingDeltaX * scale, axisY: -event.scrollingDeltaY * scale)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateTrackingAreas()
    }

    private func setupNotifications() {
        let frameToken = NotificationCenter.default.addObserver(
            forName: .waylandFrame,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else {
                return
            }
            let source = notification.userInfo?["source"] as? String ?? "unknown"
            if let sharedFrame = notification.userInfo?["sharedFrame"] as? RuntimeGUISharedFrame,
               sharedFrame.sessionId == self.guiSession.id {
                self.handleSharedFrame(sharedFrame, source: source)
                return
            }
            guard let envelope = notification.userInfo?["envelope"] as? RuntimeGUIDisplayEnvelope,
                  let frame = envelope.frame,
                  frame.sessionId == self.guiSession.id else {
                return
            }
            self.handleFrame(frame, source: source)
        }
        let imeToken = NotificationCenter.default.addObserver(
            forName: .waylandIME,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let envelope = notification.userInfo?["envelope"] as? RuntimeGUIDisplayEnvelope,
                  let state = envelope.imeState,
                  state.sessionId == self.guiSession.id else {
                return
            }
                self.applyIMEState(state)
        }
        let cursorToken = NotificationCenter.default.addObserver(
            forName: .waylandCursor,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let cursor = notification.userInfo?["cursor"] as? RuntimeGUICursor,
                  cursor.sessionId == self.guiSession.id else {
                return
            }
            self.applyWaylandCursor(cursor)
        }
        let windowEventToken = NotificationCenter.default.addObserver(
            forName: .waylandWindowEvent,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let event = notification.userInfo?["event"] as? RuntimeGUIWindowEvent,
                  event.sessionId == self.guiSession.id else {
                return
            }
            self.handleWaylandWindowEvent(event)
        }
        notificationTokens = [frameToken, imeToken, cursorToken, windowEventToken]
    }

    override func keyDown(with event: NSEvent) {
        let traceID = keyboardTraceID(kind: "down", event: event)
        if hasMarkedText(), inputContext?.handleEvent(event) == true {
            appendWaylandKeyboardLog(String(
                format: "wayland_key_ime_consumed trace_id=%@ guiSessionId=%@ appkitKeyCode=%u markedLength=%d",
                traceID,
                guiSession.id,
                event.keyCode,
                markedTextValue.length
            ))
            return
        }
        if shouldRouteToTextInput(event) {
            appendWaylandKeyboardLog(String(
                format: "wayland_key_text_input trace_id=%@ guiSessionId=%@ appkitKeyCode=%u characters=%@",
                traceID,
                guiSession.id,
                event.keyCode,
                event.characters ?? ""
            ))
            interpretKeyEvents([event])
            return
        }
        if let keycode = linuxEvdevKeycode(for: event) {
            appendWaylandKeyboardLog(String(
                format: "wayland_key_down trace_id=%@ guiSessionId=%@ keyWindow=%@ appkitKeyCode=%u evdevKeyCode=%u modifiers=%u characters=%@ firstResponder=%@",
                traceID,
                guiSession.id,
                String(window?.isKeyWindow == true),
                event.keyCode,
                keycode,
                waylandModifiers(from: event),
                event.charactersIgnoringModifiers ?? "",
                String(describing: window?.firstResponder)
            ))
            postWaylandRuntimeControl(
                op: "gui_send_keyboard",
                session: guiSession,
                argv: [
                    "1",
                    String(keycode),
                    String(waylandModifiers(from: event)),
                    String(Self.timestampMs()),
                    traceID
                ]
            )
        } else {
            appendWaylandKeyboardLog(String(
                format: "wayland_key_unmapped trace_id=%@ guiSessionId=%@ keyWindow=%@ appkitKeyCode=%u characters=%@ firstResponder=%@",
                traceID,
                guiSession.id,
                String(window?.isKeyWindow == true),
                event.keyCode,
                event.charactersIgnoringModifiers ?? "",
                String(describing: window?.firstResponder)
            ))
        }
    }

    override func keyUp(with event: NSEvent) {
        let traceID = keyboardTraceID(kind: "up", event: event)
        if let keycode = linuxEvdevKeycode(for: event) {
            appendWaylandKeyboardLog(String(
                format: "wayland_key_up trace_id=%@ guiSessionId=%@ keyWindow=%@ appkitKeyCode=%u evdevKeyCode=%u modifiers=%u characters=%@ firstResponder=%@",
                traceID,
                guiSession.id,
                String(window?.isKeyWindow == true),
                event.keyCode,
                keycode,
                waylandModifiers(from: event),
                event.charactersIgnoringModifiers ?? "",
                String(describing: window?.firstResponder)
            ))
            postWaylandRuntimeControl(
                op: "gui_send_keyboard",
                session: guiSession,
                argv: [
                    "0",
                    String(keycode),
                    String(waylandModifiers(from: event)),
                    String(Self.timestampMs()),
                    traceID
                ]
            )
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let traceID = keyboardTraceID(kind: "flags", event: event)
        appendWaylandKeyboardLog(String(
            format: "wayland_flags_changed trace_id=%@ guiSessionId=%@ keyWindow=%@ appkitKeyCode=%u modifiers=%u firstResponder=%@",
            traceID,
            guiSession.id,
            String(window?.isKeyWindow == true),
            event.keyCode,
            waylandModifiers(from: event),
            String(describing: window?.firstResponder)
        ))
        postWaylandRuntimeControl(
            op: "gui_send_keyboard",
            session: guiSession,
            argv: [
                "2",
                "0",
                String(waylandModifiers(from: event)),
                String(Self.timestampMs()),
                traceID
            ]
        )
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !event.modifierFlags.contains(.command),
           event.type == .keyDown {
            appendWaylandKeyboardLog(String(
                format: "wayland_perform_key_equivalent trace_id=%@ guiSessionId=%@ appkitKeyCode=%u",
                keyboardTraceID(kind: "equiv", event: event),
                guiSession.id,
                event.keyCode
            ))
            keyDown(with: event)
            return true
        }
        return false
    }

    func handleWindowFallbackKeyEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            keyDown(with: event)
        case .keyUp:
            keyUp(with: event)
        case .flagsChanged:
            flagsChanged(with: event)
        default:
            break
        }
    }

    private func keyboardTraceID(kind: String, event: NSEvent) -> String {
        "kbd-\(guiSession.id)-\(kind)-\(event.keyCode)-\(Self.timestampMs())"
    }

    private func shouldRouteToTextInput(_ event: NSEvent) -> Bool {
        guard textInputActive,
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              let characters = event.characters,
              !characters.isEmpty else {
            return false
        }
        if [36, 48, 51, 53, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(Int(event.keyCode)) {
            return false
        }
        return characters.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) })
    }

    private func handleWaylandWindowEvent(_ event: RuntimeGUIWindowEvent) {
        switch event.eventType {
        case "moveRequested":
            guard let window,
                  let lastMouseDownEvent,
                  Date().timeIntervalSince1970 - lastMouseDownAt < 2.0 else {
                NSLog("wayland_move_request_ignored guiSessionId=%@ reason=no_recent_mouse_down", event.sessionId)
                return
            }
            moveStartWindowFrame = window.frame
            moveStartScreenPoint = window.convertPoint(toScreen: lastMouseDownEvent.locationInWindow)
            NSLog("wayland_move_session_started guiSessionId=%@ x=%.1f y=%.1f", event.sessionId, window.frame.origin.x, window.frame.origin.y)
        case "resizeRequested":
            guard let edgeValue = event.edge,
                  let edge = resizeEdge(fromXDGEdge: edgeValue),
                  let window else {
                NSLog("wayland_resize_request_ignored guiSessionId=%@ edge=%@", event.sessionId, String(describing: event.edge))
                return
            }
            resizeEdge = edge
            resizeStartWindowFrame = window.frame
            resizeStartScreenPoint = lastMouseDownEvent.map { window.convertPoint(toScreen: $0.locationInWindow) } ?? NSEvent.mouseLocation
            NSLog("wayland_resize_request_handled guiSessionId=%@ edge=%u", event.sessionId, edgeValue)
        default:
            break
        }
    }

    private func moveWindow(with event: NSEvent) {
        guard let window,
              let startFrame = moveStartWindowFrame,
              let startPoint = moveStartScreenPoint else {
            return
        }
        let currentPoint = window.convertPoint(toScreen: event.locationInWindow)
        var nextFrame = startFrame
        nextFrame.origin.x += currentPoint.x - startPoint.x
        nextFrame.origin.y += currentPoint.y - startPoint.y
        window.setFrameOrigin(nextFrame.origin)
        NSLog("wayland_move_session_updated guiSessionId=%@ x=%.1f y=%.1f", guiSession.id, nextFrame.origin.x, nextFrame.origin.y)
    }


    func insertText(_ insertString: Any, replacementRange: NSRange) {
        let string = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        let targetRange = resolvedDocumentReplacementRange(replacementRange)
        replaceCharacters(in: targetRange, with: string)
        markedTextValue = NSAttributedString(string: "")
        markedTextRange = NSRange(location: NSNotFound, length: 0)
        preeditSelectionRange = NSRange(location: 0, length: 0)
        lastReplacementRange = targetRange
        imeLabel.stringValue = string.isEmpty ? "IME: inactive" : "IME commit: \(string)"
        pushIMEState(committed: string, preedit: nil)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let resolved = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        let targetRange = resolvedDocumentReplacementRange(replacementRange)
        markedTextValue = resolved
        markedTextRange = NSRange(location: targetRange.location, length: resolved.length)
        preeditSelectionRange = selectedRange.location == NSNotFound ? NSRange(location: resolved.length, length: 0) : selectedRange
        selectedTextRange = NSRange(
            location: targetRange.location + preeditSelectionRange.location,
            length: preeditSelectionRange.length
        )
        lastReplacementRange = targetRange
        imeLabel.stringValue = resolved.string.isEmpty ? "IME: inactive" : "IME preedit: \(resolved.string)"
        pushIMEState(committed: nil, preedit: resolved.string)
    }

    func unmarkText() {
        let committed = markedTextValue.string
        if !committed.isEmpty {
            replaceCharacters(in: resolvedDocumentReplacementRange(NSRange(location: NSNotFound, length: 0)), with: committed)
        }
        markedTextValue = NSAttributedString(string: "")
        markedTextRange = NSRange(location: NSNotFound, length: 0)
        preeditSelectionRange = NSRange(location: 0, length: 0)
        imeLabel.stringValue = "IME: inactive"
        pushIMEState(committed: committed.isEmpty ? nil : committed, preedit: nil)
    }

    func hasMarkedText() -> Bool {
        markedTextValue.length > 0
    }

    func markedRange() -> NSRange {
        markedTextValue.length > 0 ? markedTextRange : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        selectedTextRange
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.foregroundColor, .backgroundColor]
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let text = surroundingText as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        actualRange?.pointee = range
        return NSAttributedString(string: text.substring(with: range))
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let window else { return .zero }
        let local = NSRect(
            x: CGFloat(cursorRect.x),
            y: bounds.height - CGFloat(cursorRect.y + max(cursorRect.height, 1)),
            width: CGFloat(max(cursorRect.width, 1)),
            height: CGFloat(max(cursorRect.height, 1))
        )
        let screenRect = window.convertToScreen(convert(local, to: nil))
        return screenRect
    }

    func characterIndex(for point: NSPoint) -> Int {
        selectedTextRange.location
    }

    func conversationIdentifier() -> Int {
        hash
    }

    override func doCommand(by selector: Selector) {
        guard let name = NSStringFromSelector(selector).components(separatedBy: ":").first else {
            return
        }
        imeLabel.stringValue = "Command: \(name)"
    }

    private func replaceCharacters(in range: NSRange, with string: String) {
        let ns = surroundingText as NSString
        let targetRange: NSRange
        if range.location == NSNotFound {
            targetRange = selectedTextRange.location == NSNotFound
                ? NSRange(location: ns.length, length: 0)
                : selectedTextRange
        } else {
            targetRange = range
        }
        guard targetRange.location != NSNotFound, NSMaxRange(targetRange) <= ns.length else {
            surroundingText.append(string)
            selectedTextRange = NSRange(location: surroundingText.utf16.count, length: 0)
            return
        }
        surroundingText = ns.replacingCharacters(in: targetRange, with: string)
        let nextLocation = targetRange.location + (string as NSString).length
        selectedTextRange = NSRange(location: nextLocation, length: 0)
    }

    private func resolvedDocumentReplacementRange(_ range: NSRange) -> NSRange {
        if range.location != NSNotFound {
            return range
        }
        if markedTextRange.location != NSNotFound, lastReplacementRange.location != NSNotFound {
            return lastReplacementRange
        }
        return selectedTextRange.location == NSNotFound
            ? NSRange(location: (surroundingText as NSString).length, length: 0)
            : selectedTextRange
    }

    private func pushIMEState(committed: String?, preedit: String?) {
        let state = RuntimeGUIIMEState(
            sessionId: guiSession.id,
            enabled: textInputActive,
            surroundingText: surroundingText,
            cursorUTF16Offset: selectedTextRange.location,
            anchorUTF16Offset: selectedTextRange.location,
            preedit: preedit,
            committed: committed,
            markedRangeUTF16: runtimeRange(markedTextRange),
            preeditSelectionUTF16: runtimeRange(preeditSelectionRange),
            replacementRangeUTF16: runtimeRange(lastReplacementRange),
            preeditCursorBeginUTF16: preeditSelectionRange.location,
            preeditCursorEndUTF16: NSMaxRange(preeditSelectionRange),
            compositionActive: hasMarkedText(),
            cursorRect: cursorRect
        )
        postWaylandRuntimeControl(op: "gui_send_ime_state", session: guiSession, imeState: state)
        appendWaylandKeyboardLog(String(
            format: "wayland_ime_state_sent guiSessionId=%@ enabled=%@ preeditLength=%d committedLength=%d",
            guiSession.id,
            String(textInputActive),
            preedit?.count ?? 0,
            committed?.count ?? 0
        ))
    }

    private func applyIMEState(_ state: RuntimeGUIIMEState) {
        let previousActive = textInputActive
        textInputActive = state.enabled
        if previousActive != textInputActive {
            NSLog("wayland_text_input_active_changed guiSessionId=%@ active=%@", guiSession.id, String(textInputActive))
        }
        surroundingText = state.surroundingText
        selectedTextRange = NSRange(
            location: min(state.cursorUTF16Offset, state.anchorUTF16Offset),
            length: abs(state.anchorUTF16Offset - state.cursorUTF16Offset)
        )
        if let rect = state.cursorRect {
            cursorRect = rect
            inputContext?.invalidateCharacterCoordinates()
        }
        if !textInputActive {
            markedTextValue = NSAttributedString(string: "")
            markedTextRange = NSRange(location: NSNotFound, length: 0)
            preeditSelectionRange = NSRange(location: 0, length: 0)
            imeLabel.stringValue = "IME: inactive"
        }
    }

    private func runtimeRange(_ range: NSRange) -> RuntimeGUITextRange? {
        guard range.location != NSNotFound else {
            return nil
        }
        return RuntimeGUITextRange(location: range.location, length: range.length)
    }

    private func handleFrame(_ frame: RuntimeGUIFrame, source: String) {
        do {
            try applyDamageRects(from: frame, to: &backingBuffer)
            let data = frame.pixelFormat == .bgra8888
                ? backingBuffer
                : convertRGBAToBGRA(backingBuffer, stride: frame.stride, height: frame.height)
            try drawMetalFrame(frame, data: data)
            applyInitialFrameSize(width: frame.width, height: frame.height)
            if !hasDrawnFrame {
                hasDrawnFrame = true
                statusLabel.isHidden = true
                imeLabel.isHidden = true
                NSApp.activate(ignoringOtherApps: true)
                claimKeyboardFocus(reason: "firstFrame")
                window?.makeKeyAndOrderFront(nil)
                window?.orderFrontRegardless()
            }
            NSLog("wayland_metal_drawn guiSessionId=%@ width=%d height=%d damage=%d source=%@", frame.sessionId, frame.width, frame.height, frame.damageRects.count, source)
        } catch {
            NSLog("wayland_metal_draw_failed guiSessionId=%@ error=%@", frame.sessionId, String(describing: error))
        }
    }

    private func handleSharedFrame(_ frame: RuntimeGUISharedFrame, source: String) {
        do {
            try drawMetalSharedFrame(frame)
            applyInitialFrameSize(width: frame.width, height: frame.height)
            if !hasDrawnFrame {
                hasDrawnFrame = true
                statusLabel.isHidden = true
                imeLabel.isHidden = true
                NSApp.activate(ignoringOtherApps: true)
                claimKeyboardFocus(reason: "firstSharedFrame")
                window?.makeKeyAndOrderFront(nil)
                window?.orderFrontRegardless()
            }
            NSLog(
                "wayland_metal_drawn guiSessionId=%@ width=%d height=%d damage=%d source=%@ generation=%llu slot=%d",
                frame.sessionId,
                frame.width,
                frame.height,
                frame.damageRects.count,
                source,
                frame.generation,
                frame.slot
            )
        } catch {
            NSLog("wayland_metal_draw_failed guiSessionId=%@ source=%@ error=%@", frame.sessionId, source, String(describing: error))
        }
    }

    private func applyInitialFrameSize(width: Int, height: Int) {
        guard !hasAppliedInitialFrameSize,
              width > 0,
              height > 0,
              let window else {
            return
        }
        hasAppliedInitialFrameSize = true
        let size = NSSize(width: width, height: height)
        guard window.contentLayoutRect.size != size else {
            lastSentGeometry = size
            return
        }
        suppressGeometryUpdate = true
        window.setContentSize(size)
        suppressGeometryUpdate = false
        lastSentGeometry = size
    }

    private func sendGeometryIfNeeded(_ size: NSSize) {
        guard !suppressGeometryUpdate else {
            return
        }
        let normalized = NSSize(width: max(1, Int(size.width)), height: max(1, Int(size.height)))
        guard lastSentGeometry != normalized else {
            return
        }
        lastSentGeometry = normalized
        postWaylandRuntimeControl(
            op: "gui_set_geometry",
            session: guiSession,
            argv: [String(Int(normalized.width)), String(Int(normalized.height))]
        )
    }

    private func drawMetalSharedFrame(_ frame: RuntimeGUISharedFrame) throws {
        guard frame.width > 0, frame.height > 0, frame.stride >= frame.width * 4 else {
            throw MSLRuntimeError("invalid shared frame geometry")
        }
        guard frame.slotOffset >= 0,
              frame.slotSize >= frame.stride * frame.height,
              frame.mappedSize >= frame.slotOffset + frame.slotSize else {
            throw MSLRuntimeError("invalid shared frame mapping bounds")
        }
        if sharedFrameMapping?.shmName != frame.shmName ||
            sharedFrameMapping?.layoutGeneration != frame.layoutGeneration ||
            sharedFrameMapping?.size != frame.mappedSize {
            sharedFrameMapping = try WaylandSharedFrameMapping(
                shmName: frame.shmName,
                layoutGeneration: frame.layoutGeneration,
                size: frame.mappedSize
            )
        }
        guard let mapping = sharedFrameMapping else {
            throw MSLRuntimeError("shared frame mapping unavailable")
        }
        let publishedGeneration = mapping.pointer
            .advanced(by: waylandSharedFrameGenerationOffset)
            .load(as: UInt64.self)
        guard publishedGeneration == frame.generation else {
            throw MSLRuntimeError("shared frame generation changed before draw")
        }
        let base = mapping.pointer.advanced(by: frame.slotOffset)
        try drawMetalPixels(
            width: frame.width,
            height: frame.height,
            stride: frame.stride,
            damageRects: frame.damageRects,
            base: base
        )
        let generationAfterDraw = mapping.pointer
            .advanced(by: waylandSharedFrameGenerationOffset)
            .load(as: UInt64.self)
        if generationAfterDraw != frame.generation {
            NSLog(
                "wayland_shared_frame_generation_changed guiSessionId=%@ before=%llu after=%llu",
                frame.sessionId,
                frame.generation,
                generationAfterDraw
            )
        }
    }

    private func applyWaylandCursor(_ cursor: RuntimeGUICursor) {
        guard cursor.width > 0,
              cursor.height > 0,
              cursor.width <= 512,
              cursor.height <= 512,
              cursor.stride >= cursor.width * 4 else {
            NSLog("wayland_cursor_apply_failed guiSessionId=%@ reason=invalid_geometry width=%d height=%d", cursor.sessionId, cursor.width, cursor.height)
            return
        }
        let data = cursor.decodedData
        guard data.count >= cursor.stride * cursor.height,
              let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            NSLog("wayland_cursor_apply_failed guiSessionId=%@ reason=invalid_data", cursor.sessionId)
            return
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let image = CGImage(
            width: cursor.width,
            height: cursor.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: cursor.stride,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            NSLog("wayland_cursor_apply_failed guiSessionId=%@ reason=image_create", cursor.sessionId)
            return
        }
        let nsCursor = NSCursor(
            image: NSImage(cgImage: image, size: NSSize(width: cursor.width, height: cursor.height)),
            hotSpot: NSPoint(x: cursor.hotspotX, y: cursor.hotspotY)
        )
        currentWaylandCursor = nsCursor
        nsCursor.set()
        NSLog("wayland_cursor_applied guiSessionId=%@ width=%d height=%d", cursor.sessionId, cursor.width, cursor.height)
    }

    private func drawMetalFrame(_ frame: RuntimeGUIFrame, data: Data) throws {
        guard frame.width > 0, frame.height > 0, frame.stride >= frame.width * 4 else {
            throw MSLRuntimeError("invalid frame geometry")
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                throw MSLRuntimeError("empty frame payload")
            }
            try drawMetalPixels(
                width: frame.width,
                height: frame.height,
                stride: frame.stride,
                damageRects: frame.damageRects,
                base: base
            )
        }
    }

    private func drawMetalPixels(
        width: Int,
        height: Int,
        stride: Int,
        damageRects: [RuntimeGUIFrameDamageRect],
        base: UnsafeRawPointer
    ) throws {
        guard let metalLayer = layer as? CAMetalLayer,
              let device,
              let commandQueue else {
            throw MSLRuntimeError("Metal is unavailable")
        }
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.drawableSize = CGSize(width: width, height: height)

        let size = MTLSize(width: width, height: height, depth: 1)
        var shouldUploadFullFrame = !hasDrawnFrame
        if frameTexture == nil || frameTextureSize.width != size.width || frameTextureSize.height != size.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            frameTexture = device.makeTexture(descriptor: descriptor)
            frameTextureSize = size
            shouldUploadFullFrame = true
        }
        guard let frameTexture else {
            throw MSLRuntimeError("failed to create Metal texture")
        }

        let rects = shouldUploadFullFrame
            ? [RuntimeGUIFrameDamageRect(x: 0, y: 0, width: width, height: height)]
            : damageRects.isEmpty
            ? [RuntimeGUIFrameDamageRect(x: 0, y: 0, width: width, height: height)]
            : damageRects
        for rect in rects {
            let x = max(0, min(width, rect.x))
            let y = max(0, min(height, rect.y))
            let endX = max(x, min(width, rect.x + rect.width))
            let endY = max(y, min(height, rect.y + rect.height))
            guard x < endX, y < endY else { continue }
            let offset = y * stride + x * 4
            let region = MTLRegionMake2D(x, y, endX - x, endY - y)
            frameTexture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: base.advanced(by: offset),
                bytesPerRow: stride
            )
        }

        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw MSLRuntimeError("failed to create Metal drawable")
        }
        blit.copy(
            from: frameTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: size,
            to: drawable.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func convertRGBAToBGRA(_ data: Data, stride: Int, height: Int) -> Data {
        var converted = data
        converted.withUnsafeMutableBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<height {
                let row = y * stride
                var x = 0
                while x + 3 < stride {
                    let offset = row + x
                    swap(&bytes[offset], &bytes[offset + 2])
                    x += 4
                }
            }
        }
        return converted
    }
}
