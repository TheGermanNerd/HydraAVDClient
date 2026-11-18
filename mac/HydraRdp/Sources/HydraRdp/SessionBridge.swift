import AppKit
import AuthenticationServices
import Foundation
import HydraRdpCore

struct HydraCCallbacks {
    var frame: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int32, Int32, Int32) -> Void)?
    var state: (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void)?
    var clipboard: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void)?
    var channelData: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int32) -> Void)?
    var channelClosed: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
    var authorize: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?)?
    var ended: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
}

final class DesktopSignInBroker: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let lock = NSLock()
    private var cancelled = false
    private var semaphore: DispatchSemaphore?
    private var browser: ASWebAuthenticationSession?
    private var result: String?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let browser = self.browser
        let semaphore = self.semaphore
        lock.unlock()
        if Thread.isMainThread {
            browser?.cancel()
        } else {
            DispatchQueue.main.async {
                browser?.cancel()
            }
        }
        semaphore?.signal()
    }

    func callbackURL(for authorize: URL) -> String? {
        lock.lock()
        if cancelled {
            lock.unlock()
            return nil
        }
        let semaphore = DispatchSemaphore(value: 0)
        self.semaphore = semaphore
        result = nil
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }
            self.lock.lock()
            let cancelled = self.cancelled
            self.lock.unlock()
            if cancelled {
                semaphore.signal()
                return
            }
            let session = ASWebAuthenticationSession(url: authorize, callbackURLScheme: "ms-appx-web") { url, _ in
                self.lock.lock()
                if self.result == nil {
                    self.result = url?.absoluteString
                }
                self.browser = nil
                self.lock.unlock()
                semaphore.signal()
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.lock.lock()
            self.browser = session
            let cancelledAfterCreate = self.cancelled
            self.lock.unlock()
            if cancelledAfterCreate || !session.start() {
                semaphore.signal()
            }
        }
        semaphore.wait()
        lock.lock()
        let value = result
        lock.unlock()
        return value
    }
}

@_silgen_name("hydra_session_create")
private func hydra_session_create(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ rdpText: UnsafePointer<CChar>?,
    _ password: UnsafePointer<CChar>?,
    _ gatewayPassword: UnsafePointer<CChar>?,
    _ accessToken: UnsafePointer<CChar>?,
    _ refreshToken: UnsafePointer<CChar>?,
    _ extraChannels: UnsafePointer<CChar>?,
    _ width: Int32,
    _ height: Int32,
    _ callbacks: UnsafePointer<HydraCCallbacks>?,
    _ user: UnsafeMutableRawPointer?
) -> OpaquePointer?

@_silgen_name("hydra_session_start")
private func hydra_session_start(_ session: OpaquePointer?)

@_silgen_name("hydra_session_stop")
private func hydra_session_stop(_ session: OpaquePointer?)

@_silgen_name("hydra_session_destroy")
private func hydra_session_destroy(_ session: OpaquePointer?)

@_silgen_name("hydra_session_key")
private func hydra_session_key(_ session: OpaquePointer?, _ keycode: Int32, _ down: Int32, _ unicode: UInt32)

@_silgen_name("hydra_session_mouse")
private func hydra_session_mouse(_ session: OpaquePointer?, _ x: Int32, _ y: Int32, _ button: Int32, _ down: Int32)

@_silgen_name("hydra_session_wheel")
private func hydra_session_wheel(_ session: OpaquePointer?, _ x: Int32, _ y: Int32, _ delta: Int32)

@_silgen_name("hydra_session_resize")
private func hydra_session_resize(_ session: OpaquePointer?, _ width: Int32, _ height: Int32, _ scalePercent: Int32)

@_silgen_name("hydra_session_set_clipboard")
private func hydra_session_set_clipboard(_ session: OpaquePointer?, _ utf8: UnsafePointer<CChar>?)

@_silgen_name("hydra_session_channel_write")
private func hydra_session_channel_write(_ session: OpaquePointer?, _ data: UnsafePointer<UInt8>?, _ length: Int32) -> Int32

@_silgen_name("hydra_session_channel_close")
private func hydra_session_channel_close(_ session: OpaquePointer?)

@MainActor
final class LiveSession: ObservableObject {
    @Published var status = "Connecting"
    @Published var connected = false
    let title: String
    let fullscreen: Bool
    let canvas = SessionCanvas()
    var onEnded: (() -> Void)?
    var onDesktopSize: ((Int, Int) -> Void)?
    private var reportedDesktop = CGSize.zero

    private var handle: OpaquePointer?
    private var retained: Unmanaged<LiveSession>?
    private let channel: HydraChannelClient
    private var channelTask: Task<Void, Never>?
    private var channelContinuation: AsyncStream<Data>.Continuation?
    private var applyingClipboard = false
    private var pasteboardCount = NSPasteboard.general.changeCount
    private var callbacks = HydraCCallbacks()
    private let desktopSignIn = DesktopSignInBroker()

    init(title: String, fullscreen: Bool, channel: HydraChannelClient) {
        self.title = title
        self.fullscreen = fullscreen
        self.channel = channel
    }

    func start(launch: FreeRdpLaunch, extraChannels: String) {
        let stream = AsyncStream<Data> { continuation in
            self.channelContinuation = continuation
        }
        channelTask = Task { [channel] in
            for await data in stream {
                let events = await channel.receive(data)
                for event in events {
                    switch event {
                    case let .write(bytes):
                        bytes.withUnsafeBytes { raw in
                            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                            _ = hydra_session_channel_write(self.handle, base, Int32(raw.count))
                        }
                    case .close:
                        hydra_session_channel_close(self.handle)
                    }
                }
            }
        }

        callbacks.frame = { user, pixels, width, height, stride in
            guard let user, let pixels else { return }
            let session = Unmanaged<LiveSession>.fromOpaque(user).takeUnretainedValue()
            let count = Int(stride) * Int(height)
            guard count > 0 else { return }
            let data = Data(bytes: pixels, count: count)
            let desktop = CGSize(width: Int(width), height: Int(height))
            Task { @MainActor in
                session.canvas.update(pixels: data, width: Int(width), height: Int(height), stride: Int(stride))
                if session.canvas.hasFrame {
                    session.canvas.window?.title = session.title
                }
                if desktop.width >= 200, desktop.height >= 200, desktop != session.reportedDesktop {
                    session.reportedDesktop = desktop
                    session.onDesktopSize?(Int(desktop.width), Int(desktop.height))
                }
            }
        }
        callbacks.state = { user, connected, message in
            guard let user else { return }
            let session = Unmanaged<LiveSession>.fromOpaque(user).takeUnretainedValue()
            let text = message.map { String(cString: $0) } ?? ""
            Task { @MainActor in
                session.connected = connected != 0
                if !text.isEmpty {
                    session.status = text
                    session.canvas.statusText = text
                    if connected == 0 || !session.canvas.hasFrame {
                        session.canvas.showStatus = true
                    }
                    session.canvas.needsDisplay = true
                    session.canvas.window?.title = "\(session.title) — \(text)"
                }
            }
        }
        callbacks.clipboard = { user, utf8 in
            guard let user, let utf8 else { return }
            let session = Unmanaged<LiveSession>.fromOpaque(user).takeUnretainedValue()
            let text = String(cString: utf8)
            Task { @MainActor in
                session.applyingClipboard = true
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                session.pasteboardCount = NSPasteboard.general.changeCount
                session.applyingClipboard = false
            }
        }
        callbacks.channelData = { user, bytes, length in
            guard let user, let bytes, length > 0 else { return }
            let session = Unmanaged<LiveSession>.fromOpaque(user).takeUnretainedValue()
            let data = Data(bytes: bytes, count: Int(length))
            Task { @MainActor in
                session.channelContinuation?.yield(data)
            }
        }
        callbacks.channelClosed = { user in
            guard let user else { return }
            let session = Unmanaged<LiveSession>.fromOpaque(user).takeUnretainedValue()
            Task { @MainActor in
                session.status = "Hydra channel closed"
            }
        }
        callbacks.authorize = { user, urlPointer in
            guard let user, let urlPointer else { return nil }
            let session = Unmanaged<LiveSession>.fromOpaque(user).takeUnretainedValue()
            guard let url = URL(string: String(cString: urlPointer)) else { return nil }
            guard let callback = session.desktopSignIn.callbackURL(for: url) else { return nil }
            return strdup(callback)
        }
        callbacks.ended = { user in
            guard let user else { return }
            let session = Unmanaged<LiveSession>.fromOpaque(user).takeUnretainedValue()
            Task { @MainActor in
                session.onEnded?()
            }
        }

        let retained = Unmanaged.passRetained(self)
        self.retained = retained
        let user = retained.toOpaque()
        let arguments = launch.arguments
        let pointers = arguments.map { strdup($0) }
        var cargs: [UnsafeMutablePointer<CChar>?] = pointers
        cargs.append(nil)
        let argc = Int32(arguments.count)
        handle = cargs.withUnsafeMutableBufferPointer { buffer in
            withCString(launch.rdpText) { rdp in
                withCString(launch.password) { password in
                    withCString(launch.gatewayPassword) { gatewayPassword in
                        withCString(launch.accessToken) { token in
                            withCString(launch.refreshToken) { refresh in
                                extraChannels.withCString { extra in
                                    withUnsafePointer(to: callbacks) { callbackPointer in
                                        hydra_session_create(
                                            argc,
                                            buffer.baseAddress,
                                            rdp,
                                            password,
                                            gatewayPassword,
                                            token,
                                            refresh,
                                            extra,
                                            Int32(launch.width),
                                            Int32(launch.height),
                                            callbackPointer,
                                            user
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        pointers.forEach { free($0) }
        guard handle != nil else {
            status = "Could not create the FreeRDP session"
            retained.release()
            self.retained = nil
            return
        }
        canvas.onInput = { [weak self] event in
            self?.send(event)
        }
        let bounds = canvas.bounds.size
        if bounds.width > 50, bounds.height > 50 {
            resize(to: bounds, scale: canvas.window?.backingScaleFactor ?? 1)
        }
        hydra_session_start(handle)
    }

    func stop() {
        desktopSignIn.cancel()
        channelContinuation?.finish()
        channelTask?.cancel()
        hydra_session_stop(handle)
        hydra_session_destroy(handle)
        handle = nil
        retained?.release()
        retained = nil
    }

    func resize(to size: CGSize, scale: CGFloat) {
        let width = max(200, Int((size.width * scale).rounded()))
        let height = max(200, Int((size.height * scale).rounded()))
        let percent = scale >= 1.5 ? 200 : 100
        hydra_session_resize(handle, Int32(width), Int32(height), Int32(percent))
    }

    func publishClipboard() {
        guard !applyingClipboard else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != pasteboardCount else { return }
        pasteboardCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string) else { return }
        text.withCString { hydra_session_set_clipboard(handle, $0) }
    }

    private func send(_ event: SessionInput) {
        switch event {
        case let .key(code, down, unicode):
            hydra_session_key(handle, Int32(code), down ? 1 : 0, unicode)
        case let .mouse(x, y, button, down):
            hydra_session_mouse(handle, Int32(x), Int32(y), Int32(button), down ? 1 : 0)
        case let .wheel(x, y, delta):
            hydra_session_wheel(handle, Int32(x), Int32(y), Int32(delta))
        }
    }

    private func withCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let value else { return body(nil) }
        return value.withCString { body($0) }
    }
}

enum SessionInput {
    case key(code: Int, down: Bool, unicode: UInt32)
    case mouse(x: Int, y: Int, button: Int, down: Bool)
    case wheel(x: Int, y: Int, delta: Int)
}

final class SessionCanvas: NSView {
    var onInput: ((SessionInput) -> Void)?
    var statusText = "Connecting"
    var showStatus = true
    var hasFrame: Bool { image != nil }
    private var image: CGImage?
    private var desktop = CGSize(width: 1280, height: 720)

    override var acceptsFirstResponder: Bool { true }

    func update(pixels: Data, width: Int, height: Int, stride: Int) {
        desktop = CGSize(width: width, height: height)
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let provider = CGDataProvider(dataInfo: nil, data: base, size: raw.count) { _, _, _ in }
            let copied = CFDataCreate(nil, base.assumingMemoryBound(to: UInt8.self), raw.count)
            guard let copied, let dataProvider = CGDataProvider(data: copied) else {
                _ = provider
                return
            }
            image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: stride,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: dataProvider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
            if image != nil {
                showStatus = false
            } else {
                statusText = "Received a desktop frame that could not be shown"
                showStatus = true
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        if let image, let context = NSGraphicsContext.current?.cgContext {
            context.interpolationQuality = .none
            context.draw(image, in: bounds)
        }
        guard showStatus else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 16),
            .paragraphStyle: paragraph
        ]
        let text = statusText.isEmpty ? "Connecting" : statusText
        let size = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: 24,
            y: bounds.midY - size.height / 2,
            width: max(bounds.width - 48, 1),
            height: size.height
        )
        text.draw(in: textRect, withAttributes: attributes)
    }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        onInput?(.key(code: Int(event.keyCode), down: true, unicode: unicode(event)))
    }

    override func keyUp(with event: NSEvent) {
        onInput?(.key(code: Int(event.keyCode), down: false, unicode: unicode(event)))
    }

    override func flagsChanged(with event: NSEvent) {
        let code = Int(event.keyCode)
        let down = modifierDown(event)
        onInput?(.key(code: code, down: down, unicode: 0))
    }

    override func mouseDown(with event: NSEvent) { mouse(event, button: 1, down: true) }
    override func mouseUp(with event: NSEvent) { mouse(event, button: 1, down: false) }
    override func rightMouseDown(with event: NSEvent) { mouse(event, button: 2, down: true) }
    override func rightMouseUp(with event: NSEvent) { mouse(event, button: 2, down: false) }
    override func otherMouseDown(with event: NSEvent) { mouse(event, button: 3, down: true) }
    override func otherMouseUp(with event: NSEvent) { mouse(event, button: 3, down: false) }
    override func mouseDragged(with event: NSEvent) { mouse(event, button: 0, down: false) }
    override func mouseMoved(with event: NSEvent) { mouse(event, button: 0, down: false) }

    override func scrollWheel(with event: NSEvent) {
        let point = remotePoint(event)
        let notches = Int((event.scrollingDeltaY / 10).rounded())
        let delta = notches == 0 ? (event.scrollingDeltaY > 0 ? 120 : -120) : notches * 120
        onInput?(.wheel(x: point.x, y: point.y, delta: delta))
    }

    private func mouse(_ event: NSEvent, button: Int, down: Bool) {
        let point = remotePoint(event)
        onInput?(.mouse(x: point.x, y: point.y, button: button, down: down))
    }

    private func remotePoint(_ event: NSEvent) -> (x: Int, y: Int) {
        let local = convert(event.locationInWindow, from: nil)
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        let x = Int((local.x / width) * desktop.width)
        let y = Int(((height - local.y) / height) * desktop.height)
        return (min(max(x, 0), Int(desktop.width) - 1), min(max(y, 0), Int(desktop.height) - 1))
    }

    private func unicode(_ event: NSEvent) -> UInt32 {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return 0 }
        return scalar.value <= 0xFFFF ? scalar.value : 0
    }

    private func modifierDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 55, 54: return event.modifierFlags.contains(.command)
        case 56, 60: return event.modifierFlags.contains(.shift)
        case 58, 61: return event.modifierFlags.contains(.option)
        case 59, 62: return event.modifierFlags.contains(.control)
        case 57: return event.modifierFlags.contains(.capsLock)
        default: return true
        }
    }
}

enum SessionPresenter {
    @MainActor
    static func open(session: LiveSession, launch: FreeRdpLaunch, extraChannels: String) {
        SessionWindowController(session: session, launch: launch).show(extraChannels: extraChannels)
    }
}

/// Owns the session window for as long as it is open. A local NSWindow is released
/// when `open` returns, which left the AVD session running with nothing on screen.
@MainActor
final class SessionWindowController: NSObject, NSWindowDelegate {
    private static var openControllers: [SessionWindowController] = []

    private let session: LiveSession
    private let launch: FreeRdpLaunch
    private let window: NSWindow
    private var clipboardTimer: Timer?
    private var stopped = false
    private var closeAfterFullscreenExit = false
    private var fittingDesktop = false
    private var didPositionForDesktop = false

    init(session: LiveSession, launch: FreeRdpLaunch) {
        self.session = session
        self.launch = launch
        let size = Self.contentSize
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = session.title
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 320, height: 200)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        session.canvas.translatesAutoresizingMaskIntoConstraints = true
        session.canvas.autoresizingMask = [.width, .height]
        window.contentView = session.canvas
        window.setContentSize(size)
        window.center()
    }

    func show(extraChannels: String) {
        Self.openControllers.append(self)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(session.canvas)
        session.onDesktopSize = { [weak self] width, height in
            self?.fitWindow(toPixelWidth: width, height: height)
        }
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.session.publishClipboard()
            }
        }
        session.onEnded = { [weak self] in
            self?.closeFromRemoteEnd()
        }
        session.start(launch: launch, extraChannels: extraChannels)
        if session.fullscreen {
            window.toggleFullScreen(nil)
        }
    }

    private func closeFromRemoteEnd() {
        guard !stopped else { return }
        if window.styleMask.contains(.fullScreen) {
            closeAfterFullscreenExit = true
            window.toggleFullScreen(nil)
            return
        }
        window.close()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !stopped, !fittingDesktop else { return }
        syncRemoteToWindow()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard !stopped else { return }
        syncRemoteToWindow()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard !stopped else { return }
        if closeAfterFullscreenExit {
            closeAfterFullscreenExit = false
            window.close()
            return
        }
        syncRemoteToWindow()
    }

    func windowWillClose(_ notification: Notification) {
        guard !stopped else { return }
        stopped = true
        clipboardTimer?.invalidate()
        session.stop()
        Self.openControllers.removeAll { $0 === self }
    }

    /// Matches the local window to the desktop the session actually connected with.
    /// A desktop larger than the screen is clamped, and that smaller size is sent back.
    private func fitWindow(toPixelWidth width: Int, height: Int) {
        guard !stopped, width >= 200, height >= 200 else { return }
        if session.fullscreen || window.styleMask.contains(.fullScreen) {
            syncRemoteToWindow()
            return
        }
        let scale = max(window.backingScaleFactor, 1)
        var points = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: points))
            if frame.width > visible.width || frame.height > visible.height {
                let factor = min(visible.width / frame.width, visible.height / frame.height)
                points.width = floor(points.width * factor)
                points.height = floor(points.height * factor)
            }
        }
        points.width = max(points.width, 320)
        points.height = max(points.height, 240)
        let current = session.canvas.bounds.size
        if abs(current.width - points.width) > 1 || abs(current.height - points.height) > 1 {
            fittingDesktop = true
            window.setContentSize(points)
            if !didPositionForDesktop {
                window.center()
                didPositionForDesktop = true
            }
            fittingDesktop = false
        }
        let pixelWidth = session.canvas.bounds.width * scale
        let pixelHeight = session.canvas.bounds.height * scale
        if abs(pixelWidth - CGFloat(width)) > 4 || abs(pixelHeight - CGFloat(height)) > 4 {
            syncRemoteToWindow()
        }
    }

    private func syncRemoteToWindow() {
        guard !stopped else { return }
        let size = session.canvas.bounds.size
        guard size.width > 50, size.height > 50 else { return }
        session.resize(to: size, scale: window.backingScaleFactor)
    }

    private static var contentSize: NSSize {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        return NSSize(width: max(visible.width - 48, 320), height: max(visible.height - 48, 240))
    }
}
