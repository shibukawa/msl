import Foundation

public enum RuntimeGUISessionLifecycleState: String, Codable {
    case launching
    case running
    case stopping
    case stopped
    case error
}

public enum RuntimeGUIFramePixelFormat: String, Codable {
    case bgra8888
    case rgba8888
}

public struct RuntimeGUIDisplayDescriptor: Codable, Equatable {
    public var displayName: String
    public var port: Int
    public var width: Int
    public var height: Int
    public var scaleFactor: Double

    public init(
        displayName: String,
        port: Int,
        width: Int = 1280,
        height: Int = 800,
        scaleFactor: Double = 2.0
    ) {
        self.displayName = displayName
        self.port = port
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
    }
}

public struct RuntimeGUISession: Codable, Equatable, Identifiable {
    public var id: String
    public var instanceName: String
    public var sessionId: String
    public var procId: String?
    public var title: String
    public var command: [String]
    public var state: RuntimeGUISessionLifecycleState
    public var display: RuntimeGUIDisplayDescriptor
    public var lastError: String?
    public var startedAtEpochMs: Int64
    public var lastUpdatedEpochMs: Int64

    public init(
        id: String,
        instanceName: String,
        sessionId: String,
        procId: String? = nil,
        title: String,
        command: [String],
        state: RuntimeGUISessionLifecycleState,
        display: RuntimeGUIDisplayDescriptor,
        lastError: String? = nil,
        startedAtEpochMs: Int64,
        lastUpdatedEpochMs: Int64
    ) {
        self.id = id
        self.instanceName = instanceName
        self.sessionId = sessionId
        self.procId = procId
        self.title = title
        self.command = command
        self.state = state
        self.display = display
        self.lastError = lastError
        self.startedAtEpochMs = startedAtEpochMs
        self.lastUpdatedEpochMs = lastUpdatedEpochMs
    }
}

public struct RuntimeGUIFrameDamageRect: Codable, Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct RuntimeGUIFrame: Codable, Equatable {
    public var sessionId: String
    public var width: Int
    public var height: Int
    public var stride: Int
    public var pixelFormat: RuntimeGUIFramePixelFormat
    public var damageRects: [RuntimeGUIFrameDamageRect]
    public var dataBase64: String
    public var epochMs: Int64
    public var rawData: Data? = nil

    enum CodingKeys: String, CodingKey {
        case sessionId
        case width
        case height
        case stride
        case pixelFormat
        case damageRects
        case dataBase64
        case epochMs
    }

    public init(
        sessionId: String,
        width: Int,
        height: Int,
        stride: Int,
        pixelFormat: RuntimeGUIFramePixelFormat,
        damageRects: [RuntimeGUIFrameDamageRect],
        dataBase64: String,
        epochMs: Int64,
        rawData: Data? = nil
    ) {
        self.sessionId = sessionId
        self.width = width
        self.height = height
        self.stride = stride
        self.pixelFormat = pixelFormat
        self.damageRects = damageRects
        self.dataBase64 = dataBase64
        self.epochMs = epochMs
        self.rawData = rawData
    }

    public var decodedData: Data {
        rawData ?? Data(base64Encoded: dataBase64) ?? Data()
    }
}

public struct RuntimeGUISharedFrame: Codable, Equatable {
    public var sessionId: String
    public var shmName: String
    public var width: Int
    public var height: Int
    public var stride: Int
    public var pixelFormat: RuntimeGUIFramePixelFormat
    public var damageRects: [RuntimeGUIFrameDamageRect]
    public var slot: Int
    public var slotOffset: Int
    public var slotSize: Int
    public var mappedSize: Int
    public var generation: UInt64
    public var layoutGeneration: UInt64
    public var epochMs: Int64

    public init(
        sessionId: String,
        shmName: String,
        width: Int,
        height: Int,
        stride: Int,
        pixelFormat: RuntimeGUIFramePixelFormat,
        damageRects: [RuntimeGUIFrameDamageRect],
        slot: Int,
        slotOffset: Int,
        slotSize: Int,
        mappedSize: Int,
        generation: UInt64,
        layoutGeneration: UInt64,
        epochMs: Int64
    ) {
        self.sessionId = sessionId
        self.shmName = shmName
        self.width = width
        self.height = height
        self.stride = stride
        self.pixelFormat = pixelFormat
        self.damageRects = damageRects
        self.slot = slot
        self.slotOffset = slotOffset
        self.slotSize = slotSize
        self.mappedSize = mappedSize
        self.generation = generation
        self.layoutGeneration = layoutGeneration
        self.epochMs = epochMs
    }
}

public struct RuntimeGUIIMEState: Codable, Equatable {
    public var sessionId: String
    public var enabled: Bool
    public var surroundingText: String
    public var cursorUTF16Offset: Int
    public var anchorUTF16Offset: Int
    public var preedit: String?
    public var committed: String?
    public var deleteLeftUTF16Count: Int
    public var deleteRightUTF16Count: Int
    public var markedRangeUTF16: RuntimeGUITextRange?
    public var preeditSelectionUTF16: RuntimeGUITextRange?
    public var replacementRangeUTF16: RuntimeGUITextRange?
    public var preeditCursorBeginUTF16: Int?
    public var preeditCursorEndUTF16: Int?
    public var compositionActive: Bool?
    public var cursorRect: RuntimeGUICursorRect?

    public init(
        sessionId: String,
        enabled: Bool = false,
        surroundingText: String,
        cursorUTF16Offset: Int,
        anchorUTF16Offset: Int,
        preedit: String? = nil,
        committed: String? = nil,
        deleteLeftUTF16Count: Int = 0,
        deleteRightUTF16Count: Int = 0,
        markedRangeUTF16: RuntimeGUITextRange? = nil,
        preeditSelectionUTF16: RuntimeGUITextRange? = nil,
        replacementRangeUTF16: RuntimeGUITextRange? = nil,
        preeditCursorBeginUTF16: Int? = nil,
        preeditCursorEndUTF16: Int? = nil,
        compositionActive: Bool? = nil,
        cursorRect: RuntimeGUICursorRect? = nil
    ) {
        self.sessionId = sessionId
        self.enabled = enabled
        self.surroundingText = surroundingText
        self.cursorUTF16Offset = cursorUTF16Offset
        self.anchorUTF16Offset = anchorUTF16Offset
        self.preedit = preedit
        self.committed = committed
        self.deleteLeftUTF16Count = deleteLeftUTF16Count
        self.deleteRightUTF16Count = deleteRightUTF16Count
        self.markedRangeUTF16 = markedRangeUTF16
        self.preeditSelectionUTF16 = preeditSelectionUTF16
        self.replacementRangeUTF16 = replacementRangeUTF16
        self.preeditCursorBeginUTF16 = preeditCursorBeginUTF16
        self.preeditCursorEndUTF16 = preeditCursorEndUTF16
        self.compositionActive = compositionActive
        self.cursorRect = cursorRect
    }
}

public struct RuntimeGUITextRange: Codable, Equatable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct RuntimeGUICursorRect: Codable, Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct RuntimeGUICursor: Codable, Equatable {
    public var sessionId: String
    public var width: Int
    public var height: Int
    public var stride: Int
    public var hotspotX: Int
    public var hotspotY: Int
    public var pixelFormat: RuntimeGUIFramePixelFormat
    public var dataBase64: String
    public var epochMs: Int64

    public init(
        sessionId: String,
        width: Int,
        height: Int,
        stride: Int,
        hotspotX: Int,
        hotspotY: Int,
        pixelFormat: RuntimeGUIFramePixelFormat,
        dataBase64: String,
        epochMs: Int64
    ) {
        self.sessionId = sessionId
        self.width = width
        self.height = height
        self.stride = stride
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.pixelFormat = pixelFormat
        self.dataBase64 = dataBase64
        self.epochMs = epochMs
    }

    public var decodedData: Data {
        Data(base64Encoded: dataBase64) ?? Data()
    }
}

public struct RuntimeGUIWindowEvent: Codable, Equatable {
    public var sessionId: String
    public var eventType: String
    public var title: String?
    public var appId: String?
    public var serial: UInt32?
    public var seat: UInt32?
    public var edge: UInt32?
    public var pointerX: Double?
    public var pointerY: Double?
    public var epochMs: Int64

    public init(
        sessionId: String,
        eventType: String,
        title: String? = nil,
        appId: String? = nil,
        serial: UInt32? = nil,
        seat: UInt32? = nil,
        edge: UInt32? = nil,
        pointerX: Double? = nil,
        pointerY: Double? = nil,
        epochMs: Int64
    ) {
        self.sessionId = sessionId
        self.eventType = eventType
        self.title = title
        self.appId = appId
        self.serial = serial
        self.seat = seat
        self.edge = edge
        self.pointerX = pointerX
        self.pointerY = pointerY
        self.epochMs = epochMs
    }
}

public enum RuntimeGUIDisplayEnvelopeKind: String, Codable {
    case hello
    case frame
    case imeState
    case cursor
    case windowEvent
    case focus
    case ping
}

public struct RuntimeGUIDisplayEnvelope: Codable, Equatable {
    public var kind: RuntimeGUIDisplayEnvelopeKind
    public var session: RuntimeGUISession?
    public var frame: RuntimeGUIFrame?
    public var sharedFrame: RuntimeGUISharedFrame?
    public var imeState: RuntimeGUIIMEState?
    public var cursor: RuntimeGUICursor?
    public var windowEvent: RuntimeGUIWindowEvent?
    public var meta: [String: String]?

    public init(
        kind: RuntimeGUIDisplayEnvelopeKind,
        session: RuntimeGUISession? = nil,
        frame: RuntimeGUIFrame? = nil,
        sharedFrame: RuntimeGUISharedFrame? = nil,
        imeState: RuntimeGUIIMEState? = nil,
        cursor: RuntimeGUICursor? = nil,
        windowEvent: RuntimeGUIWindowEvent? = nil,
        meta: [String: String]? = nil
    ) {
        self.kind = kind
        self.session = session
        self.frame = frame
        self.sharedFrame = sharedFrame
        self.imeState = imeState
        self.cursor = cursor
        self.windowEvent = windowEvent
        self.meta = meta
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> RuntimeGUIDisplayEnvelope {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

public func managedGUIEnvironment(
    displayName: String,
    sessionID: String,
    port: Int
) -> [String: String] {
    var env = defaultWaylandEnvironment(displayName: displayName)
    env["MSL_GUI_SESSION_ID"] = sessionID
    env["MSL_DISPLAY_VSOCK_PORT"] = String(port)
    return env
}

public func defaultWaylandEnvironment(displayName: String = "wayland-0") -> [String: String] {
    [
        "WAYLAND_DISPLAY": displayName,
        "GDK_BACKEND": "wayland",
        "QT_QPA_PLATFORM": "wayland",
        "SDL_VIDEODRIVER": "wayland",
        "CLUTTER_BACKEND": "wayland",
        "MOZ_ENABLE_WAYLAND": "1",
        "XDG_SESSION_TYPE": "wayland",
        "XDG_RUNTIME_DIR": "/tmp",
        "MSL_WAYLAND_DISPLAY": displayName,
    ]
}

public let mslGuestWaylandProfileScriptPath = "/etc/profile.d/msl-wayland.sh"

public func mslWaylandProfileScript(displayName: String = "wayland-0") -> String {
    """
    # Installed by MSL. Enables Wayland defaults for interactive guest shells.
    export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-\(displayName)}"
    export MSL_WAYLAND_DISPLAY="${MSL_WAYLAND_DISPLAY:-$WAYLAND_DISPLAY}"
    export GDK_BACKEND="${GDK_BACKEND:-wayland}"
    export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
    export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland}"
    export CLUTTER_BACKEND="${CLUTTER_BACKEND:-wayland}"
    export MOZ_ENABLE_WAYLAND="${MOZ_ENABLE_WAYLAND:-1}"
    export XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-wayland}"
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
    """
}

public func applyDamageRects(
    from frame: RuntimeGUIFrame,
    to destination: inout Data,
    bytesPerPixel: Int = 4
) throws {
    guard bytesPerPixel > 0 else {
        throw MSLRuntimeError("bytesPerPixel must be positive")
    }
    let source = frame.decodedData
    let expectedMinimum = frame.stride * frame.height
    guard source.count >= expectedMinimum else {
        throw MSLRuntimeError("frame payload is smaller than declared geometry")
    }
    if destination.count < expectedMinimum {
        destination = Data(repeating: 0, count: expectedMinimum)
    }

    let rects = frame.damageRects.isEmpty
        ? [RuntimeGUIFrameDamageRect(x: 0, y: 0, width: frame.width, height: frame.height)]
        : frame.damageRects

    for rect in rects {
        let startX = max(0, min(frame.width, rect.x))
        let startY = max(0, min(frame.height, rect.y))
        let endX = max(startX, min(frame.width, rect.x + rect.width))
        let endY = max(startY, min(frame.height, rect.y + rect.height))
        if startX >= endX || startY >= endY {
            continue
        }
        for row in startY..<endY {
            let rowOffset = row * frame.stride
            let byteOffset = rowOffset + (startX * bytesPerPixel)
            let byteCount = (endX - startX) * bytesPerPixel
            let range = byteOffset..<(byteOffset + byteCount)
            destination.replaceSubrange(range, with: source.subdata(in: range))
        }
    }
}
