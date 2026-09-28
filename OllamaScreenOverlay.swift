import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

struct OverlayError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Settings {
    static let model = "qwen3.5:27b-mlx"
    static let endpoint = URL(string: "http://127.0.0.1:11434")!
    var prompt = "Analyze this screenshot. Explain the main visible content and any useful findings concisely. Use plain text and short paragraphs."
    var timeout: TimeInterval = 300
    var maxTokens = 2048
    var checkOnly = false
    var demo = false
    var help = false

    static let usage = """
    Usage: ./run.sh [options]
      --prompt TEXT      Instructions for analyzing the screenshot
      --timeout SECONDS  Maximum inference request duration (default: 300)
      --max-tokens N     Output token limit (default: 2048)
      --check            Check metadata and actual image input; no screenshot
      --demo             Preview a long overlay; no screenshot or API request
      --help             Show this help
    Start the app, then copy a screenshot with Control-Command-Shift-4 or -3.
    Waiting and analysis stay hidden; only answer text appears on a transparent overlay.
    Quit from the Ollama menu-bar icon, or press Escape after clicking an answer.
    """

    static func parse(_ arguments: [String]) throws -> Settings {
        var result = Settings()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" { result.help = true }
            else if argument == "--check" { result.checkOnly = true }
            else if argument == "--demo" { result.demo = true }
            else {
                guard ["--prompt", "--timeout", "--max-tokens"].contains(argument) else {
                    throw OverlayError("Unknown option: \(argument)\n\(usage)")
                }
                index += 1
                guard index < arguments.count else { throw OverlayError("Missing value for \(argument).") }
                let value = arguments[index]
                switch argument {
                case "--prompt":
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw OverlayError("The prompt cannot be empty.")
                    }
                    result.prompt = value
                case "--max-tokens":
                    guard let n = Int(value), (1...32768).contains(n) else {
                        throw OverlayError("--max-tokens must be between 1 and 32768.")
                    }
                    result.maxTokens = n
                default:
                    let range: ClosedRange<Double> = 1...3600
                    guard let seconds = Double(value), seconds.isFinite, range.contains(seconds) else {
                        throw OverlayError("\(argument) must be a number in \(range).")
                    }
                    result.timeout = seconds
                }
            }
            index += 1
        }
        guard !(result.demo && result.checkOnly) else {
            throw OverlayError("Choose either --check or --demo.")
        }
        return result
    }
}

// Do not follow redirects, even when a local server asks us to forward a POST.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct GenerationResult {
    let text: String
    let truncated: Bool
}

struct VisionProbe {
    let png: Data
    let expected: String
    static let prompt = "Read the five-digit number in the image. Reply with only those five digits."

    static func make() throws -> VisionProbe {
        let code = String(Int.random(in: 10000...99999))
        guard let context = CGContext(data: nil, width: 640, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw OverlayError("Could not allocate the image-support test.")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 240))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: code, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 100, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]))
        context.textPosition = CGPoint(x: 150, y: 90)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { throw OverlayError("Could not render the image-support test.") }
        return VisionProbe(png: try ScreenshotImage.encodePNG(image), expected: code)
    }

    func accepts(_ text: String) -> Bool {
        // Tolerate harmless prose/Markdown, but require exactly the correct digits.
        text.filter { "0123456789".contains($0) } == expected
    }
}

actor OllamaClient {
    private let session: URLSession
    private var version = "unknown"
    private var verified = false

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func preflight() async throws -> String {
        verified = false
        let info = try await request("api/version", timeout: 10)
        guard let reportedVersion = info["version"] as? String, !reportedVersion.isEmpty else {
            throw OverlayError("The local service did not return a valid Ollama version. Update/restart Ollama and check port 11434.")
        }
        version = reportedVersion
        let model = try await request("api/show", body: ["model": Settings.model], timeout: 30)
        try Self.validateModel(model, version: version)
        verified = true
        return "Ollama \(version): \(Settings.model) is installed locally and advertises image input."
    }

    func verifyImageInput(timeout: TimeInterval, probe suppliedProbe: VisionProbe? = nil) async throws {
        let probe = try suppliedProbe ?? VisionProbe.make()
        var settings = Settings()
        settings.prompt = VisionProbe.prompt
        settings.maxTokens = 128
        settings.timeout = timeout
        let result = try await analyze(png: probe.png, settings: settings)
        guard probe.accepts(result.text) else {
            throw OverlayError("Image-input verification failed for \(Settings.model) on Ollama \(version).\n\nThe model advertises vision but could not read a simple generated image. Expected \(probe.expected); received: \(result.text.prefix(400))\n\nThis can indicate an unsupported/broken MLX image pipeline or an OCR failure. Your screenshot was not submitted. Update Ollama, restart it, re-pull the model, then run ./run.sh --check. If this persists, this exact model/runtime cannot be verified for screenshot analysis.")
        }
    }

    static func validateModel(_ info: [String: Any], version: String) throws {
        if ["remote_host", "remote_model"].contains(where: { !(info[$0] as? String ?? "").isEmpty }) {
            throw OverlayError("This model points to a remote service. Install the local \(Settings.model) model; cloud inference is disabled in this app.")
        }
        if let required = info["requires"] as? String,
           version.compare(required, options: .numeric) == .orderedAscending {
            throw OverlayError("\(Settings.model) requires Ollama \(required) or newer; your server is \(version). Update Ollama and restart it.")
        }
        guard let capabilities = info["capabilities"] as? [String] else {
            throw OverlayError("Ollama \(version) did not report model capabilities. Image support cannot be verified. Update Ollama, restart the server, and pull \(Settings.model) again. No screenshot was submitted.")
        }
        guard capabilities.contains("vision") else {
            throw OverlayError("\(Settings.model) does not advertise image input in Ollama \(version). This model/build cannot be used for screenshots. Update Ollama and re-pull the vision-capable model. No text-only fallback was attempted.")
        }
    }

    func analyze(png: Data, settings: Settings) async throws -> GenerationResult {
        guard verified else { throw OverlayError("Image support must be checked before submitting a screenshot.") }
        guard !png.isEmpty else { throw OverlayError("Screenshot encoding produced no image data.") }
        // PNG bytes, base64 encoded; no data-URL prefix or filesystem path.
        let body: [String: Any] = [
            "model": Settings.model,
            "messages": [["role": "user", "content": settings.prompt,
                          "images": [png.base64EncodedString()]]],
            "stream": false,
            "think": false,
            "options": ["num_predict": settings.maxTokens]
        ]
        let json = try await request("api/chat", body: body, timeout: settings.timeout)
        return try Self.parseGeneration(json)
    }

    static func parseGeneration(_ json: [String: Any]) throws -> GenerationResult {
        guard let done = json["done"] as? Bool, done,
              let message = json["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let content = message["content"] as? String else {
            throw OverlayError("Ollama returned an invalid or incomplete response: expected a finished assistant message.")
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OverlayError("Ollama returned no answer text (possibly only thinking output). Try increasing --max-tokens or updating Ollama. The model's thinking field is not used as an answer.")
        }
        return GenerationResult(text: content, truncated: json["done_reason"] as? String == "length")
    }

    private func request(_ path: String, body: [String: Any]? = nil,
                         timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: Settings.endpoint.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            // This deadline also bounds a server that keeps sending partial bytes.
            let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask { [session] in try await session.data(for: request) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw OverlayError("Ollama returned a non-HTTP response.")
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if !(200...299).contains(http.statusCode) || json?["error"] != nil {
                let detail = (json?["error"] as? String)
                    ?? String(data: data.prefix(1200), encoding: .utf8) ?? "No error details."
                throw apiError(status: http.statusCode, path: path, detail: detail)
            }
            guard let json else { throw OverlayError("Ollama returned invalid JSON from /\(path). Update/restart the server.") }
            return json
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .cannotConnectToHost, .cannotFindHost:
                throw OverlayError("Cannot connect to Ollama at \(Settings.endpoint). Open the Ollama app or run `ollama serve`, then try again.")
            case .timedOut:
                throw OverlayError("Ollama /\(path) timed out after \(Int(timeout)) seconds. The model may still be loading or your Mac may be short of memory. For inference, try --timeout 600.")
            default:
                throw OverlayError("Connection to local Ollama failed: \(error.localizedDescription)")
            }
        }
    }

    private func apiError(status: Int, path: String, detail: String) -> OverlayError {
        let lower = detail.lowercased()
        let context = "Ollama \(version), HTTP \(status): \(detail.prefix(1600))"
        if status == 404 && lower.contains("model") && (lower.contains("not found") || lower.contains("does not exist")) {
            return OverlayError("The model \(Settings.model) is not installed. Run:\nollama pull \(Settings.model)\n\n\(context)")
        }
        if (300...399).contains(status) {
            return OverlayError("The local API attempted a redirect. Redirects are blocked to keep screenshot data local.\n\n\(context)")
        }
        if lower.contains("image") || lower.contains("vision") || lower.contains("multimodal") || lower.contains("projector") {
            return OverlayError("The installed model or Ollama runtime could not process image input. Update Ollama, restart it, and re-pull \(Settings.model). No image-free retry was made.\n\n\(context)")
        }
        if status == 404 || status == 405 || status == 501 {
            return OverlayError("The local server does not support /\(path). Update Ollama and verify that port 11434 belongs to Ollama.\n\n\(context)")
        }
        return OverlayError("Local inference failed. Check Ollama's server logs and available memory.\n\n\(context)")
    }
}

enum ScreenshotImage {
    // Decode/encode on the generic executor, keeping the overlay responsive.
    static func prepare(_ data: Data) async throws -> Data {
        try Task.checkCancellation()
        let png = try png(from: data)
        try Task.checkCancellation()
        return png
    }

    static func png(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width > 0, image.height > 0 else {
            throw OverlayError("The screenshot is incomplete or is not a supported image. Use PNG, JPEG, TIFF, or HEIF.")
        }
        // Preserve the exact PNG for the common case; normalize other image formats.
        if CGImageSourceGetType(source) as String? == UTType.png.identifier { return data }
        return try encodePNG(image)
    }

    static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw OverlayError("Could not initialize the PNG encoder.")
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder), data.length > 0 else {
            throw OverlayError("Could not encode the image as PNG.")
        }
        return data as Data
    }
}

// Read only new image payloads. Never clear or replace the user's clipboard.
@MainActor
final class ClipboardScreenshotSource {
    private let pasteboard: NSPasteboard
    private var handledChangeCount: Int
    private var pendingChangeCount: Int?
    private var pendingSince = Date()
    private let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier)
    ]

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        // Starting the app must not submit an image that was copied earlier.
        handledChangeCount = pasteboard.changeCount
    }

    func nextImage(now: Date = Date()) throws -> Data? {
        let changeCount = pasteboard.changeCount
        guard changeCount != handledChangeCount else { return nil }
        if pendingChangeCount != changeCount {
            pendingChangeCount = changeCount
            pendingSince = now
        }
        // clearContents and declaring the new types can be separate operations.
        guard let types = pasteboard.types, !types.isEmpty else { return nil }
        let supported = imageTypes.filter { types.contains($0) }
        guard !supported.isEmpty else {
            // Text and copied file URLs are not screenshot submissions.
            handledChangeCount = changeCount
            return nil
        }
        for type in supported {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                // A second copy can arrive while a lazy data provider is responding.
                guard pasteboard.changeCount == changeCount else { return nil }
                handledChangeCount = changeCount
                return data
            }
        }
        // A promised image can appear slightly later than the ownership change.
        if now.timeIntervalSince(pendingSince) >= 3 {
            handledChangeCount = changeCount
            throw OverlayError("The clipboard image could not be read. Take another screenshot with Control-Command-Shift-4 or -3.")
        }
        return nil
    }
}

@MainActor
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    private let panel: FloatingPanel
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private var escapeMonitor: Any?
    var onDismiss: (() -> Void)?

    override init() {
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 130),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.title = "Ollama Screen Overlay"

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .white
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        panel.contentView?.addSubview(scrollView)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }
            return event
        }
    }

    deinit { if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) } }

    func show(text: String) {
        // A shadow on the glyphs keeps text readable without painting a box.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white,
            .shadow: shadow
        ]))
        layout()
        textView.scrollToBeginningOfDocument(nil)
        // Appears without taking focus away from the user's current app.
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    func layout() {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let width = min(480, visible.width * 0.40)
        let contentWidth = width - 24
        let textWidth = contentWidth
        textView.setFrameSize(NSSize(width: textWidth, height: 1))
        textView.textContainer?.containerSize = NSSize(width: textWidth - 8, height: CGFloat.greatestFiniteMagnitude)
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        let used = textView.textContainer.flatMap { textView.layoutManager?.usedRect(for: $0).height } ?? 60
        let textHeight = max(24, ceil(used) + 12)
        let maxHeight = min(380, visible.height * 0.40)
        let height = min(maxHeight, textHeight + 24)
        panel.setContentSize(NSSize(width: width, height: height))
        scrollView.frame = NSRect(x: 12, y: 12, width: contentWidth, height: height - 24)
        textView.setFrameSize(NSSize(width: textWidth, height: max(textHeight, scrollView.contentSize.height)))
        panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - width - 16, y: visible.maxY - 16))
    }

    private func close() { panel.close() }
    func windowWillClose(_ notification: Notification) { onDismiss?() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings: Settings
    private let client = OllamaClient()
    private var overlay: OverlayController?
    private var listener: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var pendingImages: [Data] = []
    private var imageSupportVerified = false
    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem(title: "Waiting for screenshot", action: nil, keyEquivalent: "")
    private let detailLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(settings: Settings) { self.settings = settings }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let overlay = OverlayController()
        overlay.onDismiss = { [weak self] in
            self?.stop()
            NSApp.terminate(nil)
        }
        self.overlay = overlay
        configureMenu()
        if settings.demo {
            let paragraphs = (1...24).map { "\($0). This is an overlay preview. Long responses wrap automatically and remain available by scrolling. Unicode also works: café, 日本語, ∑, →. This window stays compact above other apps." }
            overlay.show(text: paragraphs.joined(separator: "\n\n"))
            setStatus("Preview only")
            return
        }
        let source = ClipboardScreenshotSource()
        listener = Task {
            while !Task.isCancelled {
                do {
                    if let data = try source.nextImage() { enqueue(data) }
                } catch {
                    setStatus("Clipboard image unavailable", detail: error.localizedDescription)
                }
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
            }
        }
    }

    private func enqueue(_ data: Data) {
        pendingImages.append(data)
        overlay?.hide()
        guard work == nil else {
            setStatus("Analyzing • \(pendingImages.count) screenshot(s) queued")
            return
        }
        work = Task {
            defer { work = nil }
            while !pendingImages.isEmpty && !Task.isCancelled {
                let data = pendingImages.removeFirst()
                overlay?.hide()
                do {
                    let png = try await ScreenshotImage.prepare(data)
                    if !imageSupportVerified {
                        setStatus("Checking local Ollama…")
                        _ = try await client.preflight()
                        try Task.checkCancellation()
                        setStatus("Verifying image input…")
                        try await client.verifyImageInput(timeout: settings.timeout)
                        try Task.checkCancellation()
                        imageSupportVerified = true
                    }
                    setStatus("Analyzing screenshot…")
                    let result = try await client.analyze(png: png, settings: settings)
                    try Task.checkCancellation()
                    let status = result.truncated
                        ? "Token limit reached • Listening for next screenshot"
                        : "Ready for your next screenshot"
                    overlay?.show(text: result.text)
                    setStatus(status)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    setStatus("Unable to analyze • Still listening", detail: error.localizedDescription)
                }
            }
        }
    }

    private func configureMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Ollama Screen Overlay")
        let menu = NSMenu()
        menu.addItem(statusLine)
        detailLine.isHidden = true
        menu.addItem(detailLine)
        menu.addItem(.separator())
        let hide = menu.addItem(withTitle: "Hide answer", action: #selector(hideAnswer), keyEquivalent: "")
        hide.target = self
        let quit = menu.addItem(withTitle: "Quit Ollama Screen Overlay", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        item.menu = menu
        statusItem = item
        setStatus("Waiting for screenshot")
    }

    private func setStatus(_ text: String, detail: String? = nil) {
        statusLine.title = text
        detailLine.title = detail ?? ""
        detailLine.isHidden = detail == nil
        statusItem?.button?.toolTip = "Ollama Screen Overlay • \(text)"
    }

    @objc private func hideAnswer() { overlay?.hide() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func stop() {
        listener?.cancel()
        work?.cancel()
        pendingImages.removeAll()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) { overlay?.layout() }
    func applicationWillTerminate(_ notification: Notification) { stop() }
}

#if !TESTING
@main
enum Main {
    @MainActor static func main() {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            let launchModeOnly = arguments.first == "--launch-mode"
            if launchModeOnly { arguments.removeFirst() }
            let settings = try Settings.parse(arguments)
            if launchModeOnly {
                print(settings.help || settings.checkOnly ? "cli" : "app")
                return
            }
            if settings.help { print(Settings.usage); return }
            if settings.checkOnly {
                Task {
                    do {
                        let client = OllamaClient()
                        print(try await client.preflight())
                        try await client.verifyImageInput(timeout: settings.timeout)
                        print("Live image-input verification passed.")
                        exit(0)
                    }
                    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
                }
                dispatchMain()
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate(settings: settings)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(2)
        }
    }
}
#endif
