import AppKit
import Metal
import QuartzCore
import mslCore

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
                controller.showWindow(nil)
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
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = session.title
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
        window?.title = session.title
        hostViewController.update(session: session)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }
}

@MainActor
final class WaylandWindowHostViewController: NSViewController {
    private let hostView: WaylandWindowHostView

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
}

final class WaylandWindowHostView: NSView, NSTextInputClient {
    private let device = MTLCreateSystemDefaultDevice()
    private let statusLabel = NSTextField(labelWithString: "")
    private let imeLabel = NSTextField(labelWithString: "")
    private let frameLayer = CALayer()
    private var guiSession: RuntimeGUISession
    private var surroundingText = ""
    private var markedTextValue = NSAttributedString(string: "")
    private var selectedTextRange = NSRange(location: 0, length: 0)
    private var backingBuffer = Data()
    private var notificationTokens: [NSObjectProtocol] = []

    init(session: RuntimeGUISession) {
        self.guiSession = session
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
        metalLayer.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1.0).cgColor
        return metalLayer
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        statusLabel.frame = NSRect(x: 20, y: bounds.height - 56, width: bounds.width - 40, height: 24)
        imeLabel.frame = NSRect(x: 20, y: bounds.height - 88, width: bounds.width - 40, height: 20)
        layer?.frame = bounds
        frameLayer.frame = bounds
        WaylandCoreBridge.shared.setGeometry(
            sessionID: guiSession.id,
            width: Int(bounds.width),
            height: Int(bounds.height)
        )
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
        frameLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(frameLayer)
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        imeLabel.textColor = .secondaryLabelColor
        imeLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        addSubview(statusLabel)
        addSubview(imeLabel)
    }

    private func setupNotifications() {
        let frameToken = NotificationCenter.default.addObserver(
            forName: .waylandFrame,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let envelope = notification.userInfo?["envelope"] as? RuntimeGUIDisplayEnvelope,
                  let frame = envelope.frame,
                  frame.sessionId == self.guiSession.id else {
                return
            }
            self.handleFrame(frame)
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
        notificationTokens = [frameToken, imeToken]
    }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    func insertText(_ insertString: Any, replacementRange: NSRange) {
        let string = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        replaceCharacters(in: replacementRange, with: string)
        markedTextValue = NSAttributedString(string: "")
        imeLabel.stringValue = string.isEmpty ? "IME: inactive" : "IME commit: \(string)"
        pushIMEState(committed: string, preedit: nil)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let resolved = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        markedTextValue = resolved
        replaceCharacters(in: replacementRange, with: resolved.string)
        self.selectedTextRange = selectedRange
        imeLabel.stringValue = resolved.string.isEmpty ? "IME: inactive" : "IME preedit: \(resolved.string)"
        pushIMEState(committed: nil, preedit: resolved.string)
    }

    func unmarkText() {
        markedTextValue = NSAttributedString(string: "")
        imeLabel.stringValue = "IME: inactive"
        pushIMEState(committed: nil, preedit: nil)
    }

    func hasMarkedText() -> Bool {
        markedTextValue.length > 0
    }

    func markedRange() -> NSRange {
        markedTextValue.length > 0 ? NSRange(location: selectedTextRange.location, length: markedTextValue.length) : NSRange(location: NSNotFound, length: 0)
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
        let local = NSRect(x: 20, y: bounds.height - 116, width: 1, height: 20)
        let screenRect = window.convertToScreen(convert(local, to: nil))
        return screenRect
    }

    func characterIndex(for point: NSPoint) -> Int {
        min(surroundingText.utf16.count, max(0, Int(point.x / 8.0)))
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

    private func pushIMEState(committed: String?, preedit: String?) {
        let state = RuntimeGUIIMEState(
            sessionId: guiSession.id,
            surroundingText: surroundingText,
            cursorUTF16Offset: selectedTextRange.location,
            anchorUTF16Offset: selectedTextRange.location,
            preedit: preedit,
            committed: committed
        )
        WaylandCoreBridge.shared.sendIMEState(state)
    }

    private func applyIMEState(_ state: RuntimeGUIIMEState) {
        surroundingText = state.surroundingText
        selectedTextRange = NSRange(location: state.cursorUTF16Offset, length: max(0, state.anchorUTF16Offset - state.cursorUTF16Offset))
        if let preedit = state.preedit, !preedit.isEmpty {
            markedTextValue = NSAttributedString(string: preedit)
            imeLabel.stringValue = "IME preedit: \(preedit)"
        } else if let committed = state.committed, !committed.isEmpty {
            markedTextValue = NSAttributedString(string: "")
            imeLabel.stringValue = "IME commit: \(committed)"
        } else {
            markedTextValue = NSAttributedString(string: "")
            imeLabel.stringValue = "IME: inactive"
        }
    }

    private func handleFrame(_ frame: RuntimeGUIFrame) {
        try? applyDamageRects(from: frame, to: &backingBuffer)
        guard let image = makeImage(from: frame, data: backingBuffer.isEmpty ? frame.decodedData : backingBuffer) else {
            return
        }
        frameLayer.contents = image
    }

    private func makeImage(from frame: RuntimeGUIFrame, data: Data) -> CGImage? {
        guard frame.width > 0, frame.height > 0, frame.stride > 0 else { return nil }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo: CGBitmapInfo = frame.pixelFormat == .bgra8888
            ? [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)]
            : [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)]
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
