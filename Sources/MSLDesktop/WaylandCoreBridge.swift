import Foundation
import Darwin
import mslCore

extension Notification.Name {
    static let waylandFrame = Notification.Name("MSLWaylandFrame")
    static let waylandIME = Notification.Name("MSLWaylandIME")
    static let waylandLog = Notification.Name("MSLWaylandLog")
    static let waylandExit = Notification.Name("MSLWaylandExit")
}

private struct LoadedWaylandSymbols {
    typealias CreateFn = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias DestroyFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias StartFn = @convention(c) (UnsafeMutableRawPointer?) -> Bool
    typealias StopFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias AttachSessionFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Bool
    typealias AttachDisplayFdFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32) -> Bool
    typealias DetachSessionFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    typealias SendTextInputFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<UInt8>?, Int) -> Void
    typealias SetGeometryFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, Int32) -> Void
    typealias SendPointerFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, Double, Double, UInt32, Double, Double, UInt32, UInt32) -> Void
    typealias SendKeyboardFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, UInt32, UInt32, UInt32) -> Void
    typealias SendFocusFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Bool) -> Void
    typealias RequestCloseFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

    let create: CreateFn
    let destroy: DestroyFn
    let start: StartFn
    let stop: StopFn
    let attachSession: AttachSessionFn
    let attachDisplayFd: AttachDisplayFdFn?
    let detachSession: DetachSessionFn
    let sendTextInput: SendTextInputFn
    let setGeometry: SetGeometryFn
    let sendPointer: SendPointerFn?
    let sendKeyboard: SendKeyboardFn?
    let sendFocus: SendFocusFn?
    let requestClose: RequestCloseFn?
}

struct WaylandCoreCallbacks {
    var onFrame: (@convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void)?
    var onIMEState: (@convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void)?
    var onLog: (@convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void)?
    var onExit: (@convention(c) (Int32, UnsafeMutableRawPointer?) -> Void)?
    var onFrameShared: (@convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void)?
}

final class WaylandCoreBridge {
    static let shared = WaylandCoreBridge()

    private var dylibHandle: UnsafeMutableRawPointer?
    private var coreHandle: UnsafeMutableRawPointer?
    private var symbols: LoadedWaylandSymbols?
    private var attachedSessions: Set<String> = []
    private var warnedUnavailable = false

    private init() {}

    deinit {
        stop()
    }

    func startIfNeeded() {
        if coreHandle != nil { return }
        guard let libraryPath = resolveLibraryPath(),
              let dylibHandle = dlopen(libraryPath, RTLD_NOW) else {
            warnUnavailableOnce()
            return
        }
        guard let symbols = loadSymbols(handle: dylibHandle) else {
            dlclose(dylibHandle)
            warnUnavailableOnce()
            return
        }
        var callbacks = WaylandCoreCallbacks(
            onFrame: { bytes, count, userData in
                WaylandCoreBridge.dispatchEnvelope(bytes: bytes, count: count, userData: userData, name: .waylandFrame)
            },
            onIMEState: { bytes, count, userData in
                WaylandCoreBridge.dispatchEnvelope(bytes: bytes, count: count, userData: userData, name: .waylandIME)
            },
            onLog: { message, _ in
                guard let message else { return }
                NotificationCenter.default.post(name: .waylandLog, object: nil, userInfo: ["message": String(cString: message)])
            },
            onExit: { code, _ in
                NotificationCenter.default.post(name: .waylandExit, object: nil, userInfo: ["code": Int(code)])
            },
            onFrameShared: { bytes, count, userData in
                WaylandCoreBridge.dispatchEnvelope(bytes: bytes, count: count, userData: userData, name: .waylandFrame)
            }
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        guard let coreHandle = withUnsafePointer(to: &callbacks, { pointer in
            symbols.create(UnsafeRawPointer(pointer), userData)
        }) else {
            dlclose(dylibHandle)
            warnUnavailableOnce()
            return
        }
        self.symbols = symbols
        self.dylibHandle = dylibHandle
        self.coreHandle = coreHandle
        _ = symbols.start(coreHandle)
    }

    func stop() {
        guard let coreHandle, let symbols else { return }
        symbols.stop(coreHandle)
        attachedSessions.removeAll()
        symbols.destroy(coreHandle)
        self.coreHandle = nil
        self.symbols = nil
        if let dylibHandle {
            dlclose(dylibHandle)
            self.dylibHandle = nil
        }
    }

    func attach(session: RuntimeGUISession) {
        startIfNeeded()
        guard let coreHandle, let symbols else { return }
        if attachedSessions.contains(session.id) { return }
        session.id.withCString { pointer in
            _ = symbols.attachSession(coreHandle, pointer)
        }
        attachedSessions.insert(session.id)
    }

    func detach(sessionID: String) {
        guard let coreHandle, let symbols else { return }
        if !attachedSessions.contains(sessionID) { return }
        sessionID.withCString { pointer in
            symbols.detachSession(coreHandle, pointer)
        }
        attachedSessions.remove(sessionID)
    }

    func attachDisplayFD(sessionID: String, fd: Int32) -> Bool {
        guard let coreHandle, let symbols, let attachDisplayFd = symbols.attachDisplayFd else { return false }
        return sessionID.withCString { pointer in
            attachDisplayFd(coreHandle, pointer, fd)
        }
    }

    func sendIMEState(_ state: RuntimeGUIIMEState) {
        guard let coreHandle, let symbols else { return }
        guard let data = try? RuntimeGUIDisplayEnvelope(kind: .imeState, imeState: state).encoded() else { return }
        data.withUnsafeBytes { rawBuffer in
            state.sessionId.withCString { sessionPointer in
                symbols.sendTextInput(
                    coreHandle,
                    sessionPointer,
                    rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                    data.count
                )
            }
        }
    }

    func setGeometry(sessionID: String, width: Int, height: Int) {
        guard let coreHandle, let symbols else { return }
        sessionID.withCString { pointer in
            symbols.setGeometry(coreHandle, pointer, Int32(width), Int32(height))
        }
    }

    func sendPointer(
        sessionID: String,
        kind: Int32,
        x: Double,
        y: Double,
        button: UInt32 = 0,
        axisX: Double = 0,
        axisY: Double = 0,
        modifiers: UInt32 = 0,
        timestampMs: UInt32 = WaylandCoreBridge.timestampMs()
    ) {
        guard let coreHandle, let symbols, let sendPointer = symbols.sendPointer else { return }
        sessionID.withCString { pointer in
            sendPointer(coreHandle, pointer, kind, x, y, button, axisX, axisY, modifiers, timestampMs)
        }
    }

    func sendKeyboard(
        sessionID: String,
        kind: Int32,
        keycode: UInt32,
        modifiers: UInt32 = 0,
        timestampMs: UInt32 = WaylandCoreBridge.timestampMs()
    ) {
        guard let coreHandle, let symbols, let sendKeyboard = symbols.sendKeyboard else { return }
        sessionID.withCString { pointer in
            sendKeyboard(coreHandle, pointer, kind, keycode, modifiers, timestampMs)
        }
    }

    func sendFocus(sessionID: String, focused: Bool) {
        guard let coreHandle, let symbols, let sendFocus = symbols.sendFocus else { return }
        sessionID.withCString { pointer in
            sendFocus(coreHandle, pointer, focused)
        }
    }

    func requestClose(sessionID: String) {
        guard let coreHandle, let symbols, let requestClose = symbols.requestClose else { return }
        sessionID.withCString { pointer in
            requestClose(coreHandle, pointer)
        }
    }

    private func resolveLibraryPath() -> String? {
        if let override = ProcessInfo.processInfo.environment["MSL_WAYLAND_CORE_LIB"], !override.isEmpty {
            return override
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/libmsl_wayland_core.dylib", isDirectory: false)
            .path
        if FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        return nil
    }

    private func loadSymbols(handle: UnsafeMutableRawPointer) -> LoadedWaylandSymbols? {
        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }

        guard
            let create = load("core_create", as: LoadedWaylandSymbols.CreateFn.self),
            let destroy = load("core_destroy", as: LoadedWaylandSymbols.DestroyFn.self),
            let start = load("core_start", as: LoadedWaylandSymbols.StartFn.self),
            let stop = load("core_stop", as: LoadedWaylandSymbols.StopFn.self),
            let attachSession = load("core_attach_session", as: LoadedWaylandSymbols.AttachSessionFn.self),
            let detachSession = load("core_detach_session", as: LoadedWaylandSymbols.DetachSessionFn.self),
            let sendTextInput = load("core_send_text_input_state", as: LoadedWaylandSymbols.SendTextInputFn.self),
            let setGeometry = load("core_set_window_geometry", as: LoadedWaylandSymbols.SetGeometryFn.self)
        else {
            return nil
        }

        return LoadedWaylandSymbols(
            create: create,
            destroy: destroy,
            start: start,
            stop: stop,
            attachSession: attachSession,
            attachDisplayFd: load("core_attach_display_fd", as: LoadedWaylandSymbols.AttachDisplayFdFn.self),
            detachSession: detachSession,
            sendTextInput: sendTextInput,
            setGeometry: setGeometry,
            sendPointer: load("core_send_pointer", as: LoadedWaylandSymbols.SendPointerFn.self),
            sendKeyboard: load("core_send_keyboard", as: LoadedWaylandSymbols.SendKeyboardFn.self),
            sendFocus: load("core_send_focus", as: LoadedWaylandSymbols.SendFocusFn.self),
            requestClose: load("core_request_toplevel_close", as: LoadedWaylandSymbols.RequestCloseFn.self)
        )
    }

    private func warnUnavailableOnce() {
        guard !warnedUnavailable else { return }
        warnedUnavailable = true
        NotificationCenter.default.post(name: .waylandLog, object: nil, userInfo: [
            "message": "Wayland core library is unavailable; GUI windows stay in placeholder mode."
        ])
    }

    private static func dispatchEnvelope(
        bytes: UnsafePointer<UInt8>?,
        count: Int,
        userData: UnsafeMutableRawPointer?,
        name: Notification.Name
    ) {
        guard let bytes, count > 0 else { return }
        let data = Data(bytes: bytes, count: count)
        guard let envelope = try? RuntimeGUIDisplayEnvelope.decode(data) else { return }
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["envelope": envelope])
        _ = userData
    }

    private static func timestampMs() -> UInt32 {
        UInt32(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970 * 1000))
    }
}
