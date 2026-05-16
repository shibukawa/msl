import Foundation
import Darwin

private struct MSLCoreWaylandCallbacks {
    var onFrame: (@convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void)?
    var onIMEState: (@convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void)?
    var onLog: (@convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void)?
    var onExit: (@convention(c) (Int32, UnsafeMutableRawPointer?) -> Void)?
    var onFrameShared: (@convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void)?
    var onCursor: (@convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void)?
    var onWindowEvent: (@convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void)?
}

private struct MSLCoreWaylandSymbols {
    typealias CreateFn = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias DestroyFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias StartFn = @convention(c) (UnsafeMutableRawPointer?) -> Bool
    typealias StopFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias AttachSessionFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Bool
    typealias AttachDisplayFdFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32) -> Bool
    typealias SetGeometryFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, Int32) -> Void
    typealias SendTextInputFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<UInt8>?, Int) -> Void
    typealias SendPointerFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, Double, Double, UInt32, Double, Double, UInt32, UInt32) -> Void
    typealias SendKeyboardFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, UInt32, UInt32, UInt32) -> Void
    typealias SendKeyboardTraceFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, UInt32, UInt32, UInt32, UnsafePointer<CChar>?) -> Void
    typealias KeyboardDebugSnapshotFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<UInt8>?, Int) -> Int
    typealias SendFocusFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Bool) -> Void
    typealias RequestCloseFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

    var create: CreateFn
    var destroy: DestroyFn
    var start: StartFn
    var stop: StopFn
    var attachSession: AttachSessionFn
    var attachDisplayFd: AttachDisplayFdFn
    var setGeometry: SetGeometryFn?
    var sendTextInput: SendTextInputFn?
    var sendPointer: SendPointerFn?
    var sendKeyboard: SendKeyboardFn?
    var sendKeyboardTrace: SendKeyboardTraceFn?
    var keyboardDebugSnapshot: KeyboardDebugSnapshotFn?
    var sendFocus: SendFocusFn?
    var requestClose: RequestCloseFn?
}

public final class WaylandCoreHostBridge {
    public static let shared = WaylandCoreHostBridge()

    private let lock = NSLock()
    private let logFileLock = NSLock()
    private var dylibHandle: UnsafeMutableRawPointer?
    private var coreHandle: UnsafeMutableRawPointer?
    private var symbols: MSLCoreWaylandSymbols?
    private var logger: MSLLogger?
    private var coreLogFile: URL?
    private var frameSnapshotDir: URL?
    private var latestFrames: [String: RuntimeGUIFrame] = [:]
    private var latestSharedFrames: [String: RuntimeGUISharedFrame] = [:]
    private var latestIMEStates: [String: RuntimeGUIIMEState] = [:]
    private var frameEventHandler: ((RuntimeGUIFrame) -> Void)?
    private var sharedFrameEventHandler: ((RuntimeGUISharedFrame) -> Void)?
    private var cursorEventHandler: ((RuntimeGUICursor) -> Void)?
    private var windowEventHandler: ((RuntimeGUIWindowEvent) -> Void)?
    private var imeEventHandler: ((RuntimeGUIIMEState) -> Void)?

    private init() {}

    public func startIfNeeded(paths: MSLPaths, logger: MSLLogger?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.logger = logger
        self.coreLogFile = paths.logs.appendingPathComponent("wayland-core.log", isDirectory: false)
        self.frameSnapshotDir = paths.logs.appendingPathComponent("wayland-frames", isDirectory: true)
        if let frameSnapshotDir {
            setenv("MSL_WAYLAND_FRAME_DIR", frameSnapshotDir.path, 1)
        }
        if coreHandle != nil {
            logBridgeEvent("wayland_core_bridge_reused")
            return true
        }
        guard let libraryPath = resolveLibraryPath(paths: paths),
              let dylibHandle = dlopen(libraryPath, RTLD_NOW) else {
            logger?.log("wayland_core_unavailable", fields: ["path": resolveLibraryPath(paths: paths) ?? ""])
            appendCoreLog("wayland_core_unavailable path=\(resolveLibraryPath(paths: paths) ?? "")")
            return false
        }
        logBridgeEvent("wayland_core_library_loaded path=\(libraryPath)")
        guard let symbols = loadSymbols(handle: dylibHandle) else {
            dlclose(dylibHandle)
            logger?.log("wayland_core_symbols_missing")
            appendCoreLog("wayland_core_symbols_missing path=\(libraryPath)")
            return false
        }
        logBridgeEvent("wayland_core_symbols_loaded path=\(libraryPath)")
        var callbacks = MSLCoreWaylandCallbacks(
            onFrame: { bytes, count, userData in
                guard let bytes, count > 0, let userData else { return }
                let bridge = Unmanaged<WaylandCoreHostBridge>.fromOpaque(userData).takeUnretainedValue()
                bridge.handleFrameCallback(bytes: bytes, count: count)
            },
            onIMEState: { bytes, count, userData in
                guard let bytes, count > 0, let userData else { return }
                let bridge = Unmanaged<WaylandCoreHostBridge>.fromOpaque(userData).takeUnretainedValue()
                bridge.handleIMEStateCallback(bytes: bytes, count: count)
            },
            onLog: { message, userData in
                guard let message, let userData else { return }
                let bridge = Unmanaged<WaylandCoreHostBridge>.fromOpaque(userData).takeUnretainedValue()
                let text = String(cString: message)
                bridge.logger?.log("wayland_core", fields: ["message": text])
                bridge.appendCoreLog(text)
            },
            onExit: { code, userData in
                guard let userData else { return }
                let bridge = Unmanaged<WaylandCoreHostBridge>.fromOpaque(userData).takeUnretainedValue()
                bridge.logger?.log("wayland_core_exit", fields: ["code": String(code)])
            },
            onFrameShared: { bytes, count, userData in
                guard let bytes, count > 0, let userData else { return }
                let bridge = Unmanaged<WaylandCoreHostBridge>.fromOpaque(userData).takeUnretainedValue()
                bridge.handleSharedFrameCallback(bytes: bytes, count: count)
            },
            onCursor: { bytes, count, userData in
                guard let bytes, count > 0, let userData else { return }
                let bridge = Unmanaged<WaylandCoreHostBridge>.fromOpaque(userData).takeUnretainedValue()
                bridge.handleCursorCallback(bytes: bytes, count: count)
            },
            onWindowEvent: { bytes, count, userData in
                guard let bytes, count > 0, let userData else { return }
                let bridge = Unmanaged<WaylandCoreHostBridge>.fromOpaque(userData).takeUnretainedValue()
                bridge.handleWindowEventCallback(bytes: bytes, count: count)
            }
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        guard let coreHandle = withUnsafePointer(to: &callbacks, { pointer in
            symbols.create(UnsafeRawPointer(pointer), userData)
        }) else {
            dlclose(dylibHandle)
            logger?.log("wayland_core_create_failed")
            appendCoreLog("wayland_core_create_failed path=\(libraryPath)")
            return false
        }
        self.dylibHandle = dylibHandle
        self.coreHandle = coreHandle
        self.symbols = symbols
        let started = symbols.start(coreHandle)
        logger?.log("wayland_core_start_result", fields: ["started": String(started)])
        appendCoreLog("wayland_core_start_result started=\(started)")
        return true
    }

    public func attachDisplay(sessionID: String, fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        logBridgeEvent("wayland_core_attach_display_requested session=\(sessionID) fd=\(fd)")
        guard let coreHandle, let symbols else {
            logBridgeEvent("wayland_core_attach_display_failed session=\(sessionID) reason=not_started")
            return false
        }
        let attachedSession = sessionID.withCString { pointer in
            symbols.attachSession(coreHandle, pointer)
        }
        guard attachedSession else {
            logBridgeEvent("wayland_core_attach_session_failed session=\(sessionID)")
            return false
        }
        let attachedDisplay = sessionID.withCString { pointer in
            symbols.attachDisplayFd(coreHandle, pointer, fd)
        }
        logBridgeEvent("wayland_core_attach_display_result session=\(sessionID) fd=\(fd) attached=\(attachedDisplay)")
        return attachedDisplay
    }

    public func latestFrame(sessionID: String) -> RuntimeGUIFrame? {
        if let frame = lock.withLock({ latestFrames[sessionID] }) {
            return frame
        }
        guard let snapshotPath = frameSnapshotPath(sessionID: sessionID) else { return nil }
        let url = URL(fileURLWithPath: snapshotPath, isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let envelope = try? RuntimeGUIDisplayEnvelope.decode(data) else {
            return nil
        }
        return envelope.frame
    }

    public func latestSharedFrame(sessionID: String) -> RuntimeGUISharedFrame? {
        lock.withLock { latestSharedFrames[sessionID] }
    }

    public func frameSnapshotPath(sessionID: String) -> String? {
        guard let frameSnapshotDir else { return nil }
        return frameSnapshotDir
            .appendingPathComponent("\(sanitizeSnapshotName(sessionID)).json", isDirectory: false)
            .path
    }

    public func frameSessionIDs() -> [String] {
        lock.withLock {
            Array(Set(latestFrames.keys).union(latestSharedFrames.keys)).sorted()
        }
    }

    public func clearSessionFrames(sessionID: String) {
        lock.withLock {
            latestFrames.removeValue(forKey: sessionID)
            latestSharedFrames.removeValue(forKey: sessionID)
        }
        logger?.log("wayland_core_session_frames_cleared", fields: ["session": sessionID])
    }

    public func setFrameEventHandler(_ handler: ((RuntimeGUIFrame) -> Void)?) {
        lock.withLock {
            frameEventHandler = handler
        }
    }

    public func setSharedFrameEventHandler(_ handler: ((RuntimeGUISharedFrame) -> Void)?) {
        lock.withLock {
            sharedFrameEventHandler = handler
        }
    }

    public func setCursorEventHandler(_ handler: ((RuntimeGUICursor) -> Void)?) {
        lock.withLock {
            cursorEventHandler = handler
        }
    }

    public func setWindowEventHandler(_ handler: ((RuntimeGUIWindowEvent) -> Void)?) {
        lock.withLock {
            windowEventHandler = handler
        }
    }

    public func setIMEEventHandler(_ handler: ((RuntimeGUIIMEState) -> Void)?) {
        lock.withLock {
            imeEventHandler = handler
        }
    }

    public func sendPointer(
        sessionID: String,
        kind: Int32,
        x: Double,
        y: Double,
        button: UInt32,
        axisX: Double,
        axisY: Double,
        modifiers: UInt32,
        timestampMs: UInt32
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let coreHandle, let symbols, let sendPointer = symbols.sendPointer else { return false }
        sessionID.withCString { pointer in
            sendPointer(coreHandle, pointer, kind, x, y, button, axisX, axisY, modifiers, timestampMs)
        }
        return true
    }

    public func setGeometry(sessionID: String, width: Int32, height: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let coreHandle, let symbols, let setGeometry = symbols.setGeometry else { return false }
        sessionID.withCString { pointer in
            setGeometry(coreHandle, pointer, width, height)
        }
        return true
    }

    public func sendKeyboard(
        sessionID: String,
        kind: Int32,
        keycode: UInt32,
        modifiers: UInt32,
        timestampMs: UInt32,
        traceID: String? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let coreHandle, let symbols, let sendKeyboard = symbols.sendKeyboard else { return false }
        sessionID.withCString { pointer in
            if let sendKeyboardTrace = symbols.sendKeyboardTrace, let traceID {
                traceID.withCString { tracePointer in
                    sendKeyboardTrace(coreHandle, pointer, kind, keycode, modifiers, timestampMs, tracePointer)
                }
            } else {
                sendKeyboard(coreHandle, pointer, kind, keycode, modifiers, timestampMs)
            }
        }
        return true
    }

    public func keyboardDebugSnapshot(sessionID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let coreHandle, let symbols, let keyboardDebugSnapshot = symbols.keyboardDebugSnapshot else { return nil }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let written = sessionID.withCString { pointer in
            keyboardDebugSnapshot(coreHandle, pointer, &buffer, buffer.count)
        }
        guard written > 0 else { return nil }
        return String(bytes: buffer.prefix(written), encoding: .utf8)
    }

    public func sendFocus(sessionID: String, focused: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let coreHandle, let symbols, let sendFocus = symbols.sendFocus else { return false }
        sessionID.withCString { pointer in
            sendFocus(coreHandle, pointer, focused)
        }
        return true
    }

    public func sendIMEState(sessionID: String, state: RuntimeGUIIMEState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let coreHandle, let symbols, let sendTextInput = symbols.sendTextInput else { return false }
        guard let data = try? RuntimeGUIDisplayEnvelope(kind: .imeState, imeState: state).encoded() else { return false }
        data.withUnsafeBytes { rawBuffer in
            sessionID.withCString { pointer in
                sendTextInput(
                    coreHandle,
                    pointer,
                    rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                    data.count
                )
            }
        }
        return true
    }

    public func requestClose(sessionID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let coreHandle, let symbols, let requestClose = symbols.requestClose else { return false }
        sessionID.withCString { pointer in
            requestClose(coreHandle, pointer)
        }
        return true
    }

    private func resolveLibraryPath(paths: MSLPaths) -> String? {
        if let override = ProcessInfo.processInfo.environment["MSL_WAYLAND_CORE_LIB"], !override.isEmpty {
            return override
        }
        let staged = paths.mslHostWaylandDir
            .appendingPathComponent("libmsl_wayland_core.dylib", isDirectory: false)
            .path
        if FileManager.default.fileExists(atPath: staged) {
            return staged
        }
        return nil
    }

    private func loadSymbols(handle: UnsafeMutableRawPointer) -> MSLCoreWaylandSymbols? {
        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }
        guard
            let create = load("core_create", as: MSLCoreWaylandSymbols.CreateFn.self),
            let destroy = load("core_destroy", as: MSLCoreWaylandSymbols.DestroyFn.self),
            let start = load("core_start", as: MSLCoreWaylandSymbols.StartFn.self),
            let stop = load("core_stop", as: MSLCoreWaylandSymbols.StopFn.self),
            let attachSession = load("core_attach_session", as: MSLCoreWaylandSymbols.AttachSessionFn.self),
            let attachDisplayFd = load("core_attach_display_fd", as: MSLCoreWaylandSymbols.AttachDisplayFdFn.self)
        else {
            return nil
        }
        return MSLCoreWaylandSymbols(
            create: create,
            destroy: destroy,
            start: start,
            stop: stop,
            attachSession: attachSession,
            attachDisplayFd: attachDisplayFd,
            setGeometry: load("core_set_window_geometry", as: MSLCoreWaylandSymbols.SetGeometryFn.self),
            sendTextInput: load("core_send_text_input_state", as: MSLCoreWaylandSymbols.SendTextInputFn.self),
            sendPointer: load("core_send_pointer", as: MSLCoreWaylandSymbols.SendPointerFn.self),
            sendKeyboard: load("core_send_keyboard", as: MSLCoreWaylandSymbols.SendKeyboardFn.self),
            sendKeyboardTrace: load("core_send_keyboard_trace", as: MSLCoreWaylandSymbols.SendKeyboardTraceFn.self),
            keyboardDebugSnapshot: load("core_keyboard_debug_snapshot", as: MSLCoreWaylandSymbols.KeyboardDebugSnapshotFn.self),
            sendFocus: load("core_send_focus", as: MSLCoreWaylandSymbols.SendFocusFn.self),
            requestClose: load("core_request_toplevel_close", as: MSLCoreWaylandSymbols.RequestCloseFn.self)
        )
    }

    private func appendCoreLog(_ message: String) {
        logFileLock.lock()
        defer { logFileLock.unlock() }
        guard let coreLogFile else { return }
        do {
            try FileManager.default.createDirectory(
                at: coreLogFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let line = "\(Date().timeIntervalSince1970) \(message)\n"
            let data = Data(line.utf8)
            if !FileManager.default.fileExists(atPath: coreLogFile.path) {
                FileManager.default.createFile(atPath: coreLogFile.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: coreLogFile)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            logger?.log("wayland_core_log_write_failed", fields: ["error": String(describing: error)])
        }
    }

    private func logBridgeEvent(_ message: String) {
        logger?.log("wayland_core_bridge", fields: ["message": message])
        appendCoreLog(message)
    }

    private func handleFrameCallback(bytes: UnsafePointer<UInt8>, count: Int) {
        logger?.log("wayland_core_frame_callback", fields: ["bytes": String(count)])
        let data = Data(bytes: bytes, count: count)
        guard let envelope = try? RuntimeGUIDisplayEnvelope.decode(data),
              let frame = envelope.frame else {
            logger?.log("wayland_core_frame_decode_failed", fields: ["bytes": String(count)])
            return
        }
        lock.withLock {
            latestFrames[frame.sessionId] = frame
        }
        logger?.log("wayland_core_frame_received", fields: [
            "session": frame.sessionId,
            "width": String(frame.width),
            "height": String(frame.height),
            "damageRects": String(frame.damageRects.count)
        ])
        let handler = lock.withLock { frameEventHandler }
        handler?(frame)
    }

    private func handleSharedFrameCallback(bytes: UnsafePointer<UInt8>, count: Int) {
        logger?.log("wayland_core_shared_frame_callback", fields: ["bytes": String(count)])
        let data = Data(bytes: bytes, count: count)
        guard let envelope = try? RuntimeGUIDisplayEnvelope.decode(data),
              let sharedFrame = envelope.sharedFrame else {
            logger?.log("wayland_core_shared_frame_decode_failed", fields: ["bytes": String(count)])
            return
        }
        lock.withLock {
            latestSharedFrames[sharedFrame.sessionId] = sharedFrame
        }
        logger?.log("wayland_core_shared_frame_received", fields: [
            "session": sharedFrame.sessionId,
            "width": String(sharedFrame.width),
            "height": String(sharedFrame.height),
            "shmName": sharedFrame.shmName,
            "slot": String(sharedFrame.slot),
            "generation": String(sharedFrame.generation)
        ])
        let handler = lock.withLock { sharedFrameEventHandler }
        handler?(sharedFrame)
    }

    private func handleCursorCallback(bytes: UnsafePointer<UInt8>, count: Int) {
        logger?.log("wayland_core_cursor_callback", fields: ["bytes": String(count)])
        let data = Data(bytes: bytes, count: count)
        guard let envelope = try? RuntimeGUIDisplayEnvelope.decode(data),
              let cursor = envelope.cursor else {
            logger?.log("wayland_core_cursor_decode_failed", fields: ["bytes": String(count)])
            return
        }
        logger?.log("wayland_core_cursor_received", fields: [
            "session": cursor.sessionId,
            "width": String(cursor.width),
            "height": String(cursor.height)
        ])
        let handler = lock.withLock { cursorEventHandler }
        handler?(cursor)
    }

    private func handleIMEStateCallback(bytes: UnsafePointer<UInt8>, count: Int) {
        logger?.log("wayland_core_ime_callback", fields: ["bytes": String(count)])
        let data = Data(bytes: bytes, count: count)
        guard let envelope = try? RuntimeGUIDisplayEnvelope.decode(data),
              let state = envelope.imeState else {
            logger?.log("wayland_core_ime_decode_failed", fields: ["bytes": String(count)])
            return
        }
        lock.withLock {
            latestIMEStates[state.sessionId] = state
        }
        logger?.log("wayland_ime_state_received", fields: [
            "session": state.sessionId,
            "enabled": String(state.enabled)
        ])
        let handler = lock.withLock { imeEventHandler }
        handler?(state)
    }

    private func handleWindowEventCallback(bytes: UnsafePointer<UInt8>, count: Int) {
        logger?.log("wayland_core_window_event_callback", fields: ["bytes": String(count)])
        let data = Data(bytes: bytes, count: count)
        guard let envelope = try? RuntimeGUIDisplayEnvelope.decode(data),
              let event = envelope.windowEvent else {
            logger?.log("wayland_core_window_event_decode_failed", fields: ["bytes": String(count)])
            return
        }
        logger?.log("wayland_core_window_event_received", fields: [
            "session": event.sessionId,
            "eventType": event.eventType
        ])
        let handler = lock.withLock { windowEventHandler }
        handler?(event)
    }

    private func sanitizeSnapshotName(_ value: String) -> String {
        String(value.map { character in
            if character.unicodeScalars.allSatisfy(\.isASCII)
                && (character.isLetter || character.isNumber || character == "-" || character == "_" || character == ".") {
                return character
            }
            return "_"
        })
    }
}
