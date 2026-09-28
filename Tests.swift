import AppKit
import ImageIO

// A local URLProtocol exercises the real HTTP client without a server or screenshots.
final class MockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data)?)!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let (status, data) = try Self.handler(request) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
enum Tests {
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw OverlayError("FAILED: \(message)") }
        checks += 1
    }

    static func fails(_ expected: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch {
            try expect(error.localizedDescription.localizedCaseInsensitiveContains(expected),
                       "Expected '\(expected)', got '\(error.localizedDescription)'")
            return
        }
        throw OverlayError("FAILED: expected error containing '\(expected)'")
    }

    static func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    static func client(_ handler: @escaping (URLRequest) throws -> (Int, Data)?) -> OllamaClient {
        MockProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        return OllamaClient(configuration: configuration)
    }

    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func versionOrModel(_ request: URLRequest) -> (Int, Data) {
        request.url!.path == "/api/version"
            ? (200, json(["version": "0.20.7"]))
            : (200, json(["capabilities": ["completion", "vision"], "requires": "0.19.0"]))
    }

    static func main() async {
        do {
            if CommandLine.arguments.contains("--live") {
                try await liveVisionCheck()
                return
            }
            try await run()
            print("Passed \(checks) checks (clipboard, image decoding, mock HTTP, payload, compatibility, errors, timeout, cancellation, and CLI).")
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }

    static func liveVisionCheck() async throws {
        let probe = try VisionProbe.make()
        if CommandLine.arguments.contains("--save-probe") {
            try probe.png.write(to: URL(fileURLWithPath: ".build/vision-probe.png"))
            print("Generated test image code: \(probe.expected)")
        }
        let client = OllamaClient()
        print(try await client.preflight())
        try await client.verifyImageInput(timeout: 300, probe: probe)
        print("Live vision check passed: the model read a fresh five-digit code from an in-memory PNG.")
    }

    static func run() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6ZcUAAAAASUVORK5CYII=")!
        let probe = try VisionProbe.make()
        let decodedProbe = CGImageSourceCreateWithData(probe.png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        try expect(decodedProbe?.width == 640 && decodedProbe?.height == 240, "Vision probe must be a decodable PNG")
        try expect(probe.accepts("Number: **\(probe.expected)**"), "Allow harmless formatting in a correct probe answer")
        try expect(!probe.accepts("No image was provided."), "Reject ignored images")
        try expect(!probe.accepts("00000"), "Reject incorrect image reading")
        try await clipboardChecks(png: probe.png)
        try expect(try ScreenshotImage.png(from: probe.png) == probe.png, "Keep the received PNG bytes exactly")
        try await fails("incomplete") { _ = try ScreenshotImage.png(from: Data(probe.png.prefix(50))) }
        try await fails("supported image") { _ = try ScreenshotImage.png(from: Data("plain text".utf8)) }
        let success = client { request in
            try expect(request.url?.host == "127.0.0.1", "Request must stay on loopback")
            if request.url!.path != "/api/chat" { return versionOrModel(request) }
            let payload = try body(request)
            let messages = payload["messages"] as! [[String: Any]]
            let images = messages[0]["images"] as! [String]
            try expect(Data(base64Encoded: images[0]) == png, "PNG must round-trip exactly through base64")
            try expect(payload["stream"] as? Bool == false && payload["think"] as? Bool == false,
                       "Use a nonstreaming final answer")
            try expect(payload["model"] as? String == Settings.model, "Use the exact requested model")
            return (200, json(["done": true, "message": ["role": "assistant", "content": "First line\n日本語"], "done_reason": "stop"]))
        }
        _ = try await success.preflight()
        let response = try await success.analyze(png: png, settings: Settings())
        try expect(response.text == "First line\n日本語" && !response.truncated, "Preserve Unicode and newlines")

        let visionOK = client { request in
            request.url!.path == "/api/chat"
                ? (200, json(["done": true, "message": ["role": "assistant", "content": "31415"]]))
                : versionOrModel(request)
        }
        _ = try await visionOK.preflight()
        try await visionOK.verifyImageInput(timeout: 5, probe: VisionProbe(png: png, expected: "31415"))
        checks += 1
        try await fails("screenshot was not submitted") {
            try await visionOK.verifyImageInput(timeout: 5, probe: VisionProbe(png: png, expected: "99999"))
        }

        try await fails("must be checked") { _ = try await client { _ in nil }.analyze(png: png, settings: Settings()) }
        try await fails("no image data") { _ = try await success.analyze(png: Data(), settings: Settings()) }
        try await fails("does not advertise") { try OllamaClient.validateModel(["capabilities": ["completion"]], version: "0.20.7") }
        try await fails("cannot be verified") { try OllamaClient.validateModel([:], version: "0.1.0") }
        try await fails("requires Ollama") { try OllamaClient.validateModel(["requires": "0.19.0", "capabilities": ["vision"]], version: "0.9.0") }
        try await fails("remote service") { try OllamaClient.validateModel(["remote_host": "https://example.com", "capabilities": ["vision"]], version: "0.20.7") }
        try await fails("invalid or incomplete") { _ = try OllamaClient.parseGeneration(["done": false]) }
        try await fails("invalid or incomplete") { _ = try OllamaClient.parseGeneration(["done": true, "message": ["content": 99]]) }
        try await fails("no answer text") { _ = try OllamaClient.parseGeneration(["done": true, "message": ["role": "assistant", "content": " \n", "thinking": "Thinking only"]]) }
        let truncated = try OllamaClient.parseGeneration(["done": true, "message": ["role": "assistant", "content": "Partial"], "done_reason": "length"])
        try expect(truncated.truncated, "Identify token-limit truncation")

        for (status, payload, expected) in [
            (404, json(["error": "model 'qwen3.5:27b-mlx' not found"]), "ollama pull"),
            (400, json(["error": "model does not support images"]), "could not process image"),
            (500, json(["error": "failed to load vision projector"]), "could not process image"),
            (404, Data("404 page not found".utf8), "does not support /api/show"),
            (200, Data("not JSON".utf8), "invalid JSON"),
            (200, json(["error": "runtime failed"]), "Local inference failed"),
            (500, json(["error": "out of memory"]), "available memory"),
            (307, Data(), "redirects are blocked")
        ] {
            let failing = client { request in
                request.url!.path == "/api/version" ? versionOrModel(request) : (status, payload)
            }
            try await fails(expected) { _ = try await failing.preflight() }
        }
        for (code, expected) in [(URLError.cannotConnectToHost, "ollama serve"), (.networkConnectionLost, "Connection to local Ollama failed"), (.timedOut, "timed out")] {
            let failing = client { _ in throw URLError(code) }
            try await fails(expected) { _ = try await failing.preflight() }
        }
        let hanging = client { request in
            request.url!.path == "/api/chat" ? nil : versionOrModel(request)
        }
        _ = try await hanging.preflight()
        var short = Settings()
        short.timeout = 0.05
        try await fails("timed out") { _ = try await hanging.analyze(png: png, settings: short) }
        let task = Task { try await hanging.analyze(png: png, settings: Settings()) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; throw OverlayError("Cancellation was ignored") }
        catch is CancellationError { checks += 1 }

        for arguments in [["--delay", "2"], ["--timeout", "nan"], ["--timeout", "0"], ["--max-tokens", "0"], ["--prompt", " "], ["--prompt"], ["--unknown"], ["--demo", "--check"]] {
            var rejected = false
            do { _ = try Settings.parse(arguments) } catch { rejected = true }
            try expect(rejected, "Reject invalid CLI: \(arguments)")
        }
        let settings = try Settings.parse(["--timeout", "600", "--max-tokens", "4096", "--prompt", "Read this"])
        try expect(settings.timeout == 600 && settings.maxTokens == 4096 && settings.prompt == "Read this", "Parse valid CLI")
    }

    @MainActor
    static func clipboardChecks(png: Data) throws {
        // A private pasteboard exercises the real AppKit API without touching the user's clipboard.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.setData(png, forType: .png) else {
            throw OverlayError("The private test pasteboard is unavailable (change count: \(pasteboard.changeCount)). Run these tests with access to the macOS pasteboard service.")
        }
        let source = ClipboardScreenshotSource(pasteboard: pasteboard)
        try expect(try source.nextImage() == nil, "Ignore the image already on the clipboard at startup")

        pasteboard.clearContents()
        pasteboard.setString("Copied text", forType: .string)
        try expect(try source.nextImage() == nil, "Ignore text clipboard changes")
        pasteboard.clearContents()
        pasteboard.setString("file:///tmp/screenshot.png", forType: .fileURL)
        try expect(try source.nextImage() == nil, "Ignore copied file paths")

        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        let changeCount = pasteboard.changeCount
        try expect(try source.nextImage() == png, "Receive the exact new clipboard screenshot")
        try expect(try source.nextImage() == nil, "Read each clipboard change only once")
        try expect(pasteboard.changeCount == changeCount && pasteboard.data(forType: .png) == png,
                   "Leave the user's clipboard unchanged")

        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        try expect(try source.nextImage() == png, "A later identical screenshot is a new submission")

        pasteboard.clearContents()
        try expect(try source.nextImage() == nil, "An empty clipboard is not an image submission")
        pasteboard.setData(png, forType: .png)
        try expect(try source.nextImage() == png, "Receive an image whose types were published after the clipboard changed")

        let image = NSBitmapImageRep(data: png)!
        let tiff = image.tiffRepresentation!
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        let normalized = try ScreenshotImage.png(from: source.nextImage()!)
        let decoded = CGImageSourceCreateWithData(normalized as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        try expect(decoded?.width == 640 && decoded?.height == 240, "Convert TIFF clipboard screenshots to PNG")

        let now = Date()
        pasteboard.declareTypes([.png], owner: nil)
        try expect(try source.nextImage(now: now) == nil, "Wait for a promised image instead of losing the screenshot")
        pasteboard.setData(png, forType: .png)
        try expect(try source.nextImage(now: now.addingTimeInterval(0.5)) == png, "Accept delayed clipboard image data")

        pasteboard.declareTypes([.png], owner: nil)
        _ = try source.nextImage(now: now)
        var timedOut = false
        do { _ = try source.nextImage(now: now.addingTimeInterval(4)) }
        catch { timedOut = error.localizedDescription.contains("could not be read") }
        try expect(timedOut, "Report an unavailable clipboard image")
        try expect(try source.nextImage() == nil, "Do not repeat an unavailable clipboard error")
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        try expect(try source.nextImage() == png, "Keep listening after a clipboard failure")
    }
}
