import Foundation
import Network

// MARK: - ClaudeHookEvent

/// Decoded payload from a Claude Code hook POST.
/// `raw` retains the full dict for forward-compat; the struct is intentionally
/// non-Codable since `raw` contains `Any`.
struct ClaudeHookEvent {
    let event: String          // hook_event_name
    let sessionId: String?     // session_id
    let cwd: String?
    let toolName: String?      // tool_name
    let prompt: String?
    let source: String?        // SessionStart source: startup/resume/clear/compact
    let raw: [String: Any]

    init?(json: [String: Any]) {
        guard let ev = json["hook_event_name"] as? String else { return nil }
        self.event     = ev
        self.sessionId = json["session_id"] as? String
        self.cwd       = json["cwd"] as? String
        self.toolName  = json["tool_name"] as? String
        self.prompt    = json["prompt"] as? String
        self.source    = json["source"] as? String
        self.raw       = json
    }
}

// MARK: - EventServer

/// Localhost-only HTTP/1.1 server that receives Claude Code hook POSTs.
/// Uses `NWListener` over TCP; binds to 127.0.0.1 only.
/// Token auth via `X-DevDash-Token` header.
/// Thread safety: NSLock guards all mutable state; handler fires asynchronously on main.
final class EventServer: @unchecked Sendable {

    // MARK: - Public interface

    /// Called on the MAIN queue for every authenticated, well-formed event.
    /// Call `reply` with a JSON string (e.g. additionalContext) or nil for `{}`.
    /// The HTTP response is sent after reply is called — do not block; call it promptly.
    var onEvent: ((ClaudeHookEvent, @escaping (String?) -> Void) -> Void)?

    /// Called (from any queue) once the listener binds successfully. Argument is the resolved port.
    var onReady: ((Int) -> Void)?

    /// The port the server is actually listening on (set after `.ready`).
    private(set) var resolvedPort: Int = 0

    // MARK: - Private

    private let lock = NSLock()
    private var listener: NWListener?
    private var token: String = ""
    private var started: Bool = false

    private let devdashDir: URL = {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".devdash")
        // Create with 0700 — token is stored here
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return url
    }()

    private var endpointFile: URL { devdashDir.appendingPathComponent("event-endpoint.json") }

    // MARK: - Start / Stop

    func start() {
        lock.lock()
        let alreadyStarted = started
        lock.unlock()
        guard !alreadyStarted else { return }   // guard against double-start (#9)

        token = resolveToken()
        lock.lock()
        started = true
        lock.unlock()
        tryBind(port: 8730)
    }

    func stop() {
        lock.lock()
        let l = listener
        listener = nil
        started = false
        lock.unlock()
        l?.cancel()
    }

    // MARK: - Port binding with retry

    private func tryBind(port: Int) {
        guard port <= 8760 else {
            NSLog("[EventServer] Could not bind to any port in 8730–8760")
            return
        }
        guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else {
            tryBind(port: port + 1)
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Restrict to loopback only — never 0.0.0.0
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"), port: p)

        let l: NWListener
        do {
            l = try NWListener(using: params)
        } catch {
            NSLog("[EventServer] NWListener init error on port %d: %@", port, error.localizedDescription)
            tryBind(port: port + 1)
            return
        }

        l.newConnectionHandler = { [weak self] conn in self?.handleConnection(conn) }

        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let actual = Int(l.port?.rawValue ?? UInt16(port))
                self.lock.lock()
                self.resolvedPort = actual
                self.lock.unlock()
                self.persistEndpoint(port: actual)
                self.onReady?(actual)
                NSLog("[EventServer] Listening on 127.0.0.1:%d", actual)
            case .failed(let err):
                NSLog("[EventServer] Port %d failed: %@; retrying", port, err.localizedDescription)
                l.cancel()
                self.tryBind(port: port + 1)
            default:
                break
            }
        }

        lock.lock()
        listener = l
        lock.unlock()
        l.start(queue: .global(qos: .utility))
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))

        // Per-connection idle timeout — cancel if no complete request within 10 s (#3)
        let timedOut = NSLock()
        var didRespond = false
        let timeoutItem = DispatchWorkItem {
            timedOut.lock()
            let alreadyDone = didRespond
            timedOut.unlock()
            if !alreadyDone {
                NSLog("[EventServer] Connection timed out; cancelling")
                conn.cancel()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeoutItem)

        receiveAll(conn: conn, accumulated: Data(), timedOut: timedOut, didRespond: &didRespond, timeoutItem: timeoutItem)
    }

    /// Accumulate data until we have a complete HTTP request (headers + body).
    private func receiveAll(
        conn: NWConnection,
        accumulated: Data,
        timedOut: NSLock,
        didRespond: inout Bool,
        timeoutItem: DispatchWorkItem
    ) {
        // Cap accumulated size before header parse completes (#4)
        if accumulated.count > 1_000_000 {
            timeoutItem.cancel()
            timedOut.lock(); didRespond = true; timedOut.unlock()
            sendAndClose(httpResponse(status: 400, body: "{\"error\":\"too_large\"}"), on: conn)
            return
        }

        // Capture didRespond by reference via a box so the closure can mutate it
        let respondedBox = RespondedBox(value: didRespond)

        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buf = accumulated
            if let data { buf.append(data) }

            // Also check size cap after accumulation
            if buf.count > 1_000_000 {
                timeoutItem.cancel()
                timedOut.lock(); respondedBox.value = true; timedOut.unlock()
                self.sendAndClose(self.httpResponse(status: 400, body: "{\"error\":\"too_large\"}"), on: conn)
                return
            }

            if let (immediate, async) = self.tryProcessRequest(buf, conn: conn) {
                if let immediateData = immediate {
                    // Synchronous response (error path)
                    timeoutItem.cancel()
                    timedOut.lock(); respondedBox.value = true; timedOut.unlock()
                    self.sendAndClose(immediateData, on: conn)
                } else {
                    // Async path: async closure will send response (#2)
                    async?()
                    timeoutItem.cancel()
                    timedOut.lock(); respondedBox.value = true; timedOut.unlock()
                }
                return
            }

            if isComplete || error != nil {
                timeoutItem.cancel()
                timedOut.lock(); respondedBox.value = true; timedOut.unlock()
                self.sendAndClose(self.httpResponse(status: 400, body: "{\"error\":\"incomplete\"}"), on: conn)
                return
            }

            // Need more data — recurse (respondedBox.value propagates via the box)
            var mutResponded = respondedBox.value
            self.receiveAll(conn: conn, accumulated: buf,
                            timedOut: timedOut, didRespond: &mutResponded,
                            timeoutItem: timeoutItem)
            respondedBox.value = mutResponded
        }

        didRespond = respondedBox.value
    }

    /// Try to parse a complete HTTP/1.1 request from `buf`.
    /// Returns a tuple: (immediateResponseData?, asyncDispatchClosure?).
    /// Returns nil if the request is incomplete (need more data).
    private func tryProcessRequest(_ buf: Data, conn: NWConnection) -> (Data?, (() -> Void)?)? {
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let sepRange = buf.range(of: sep) else { return nil }

        let headerSection = buf[buf.startIndex..<sepRange.lowerBound]
        guard let headerStr = String(data: headerSection, encoding: .utf8) else {
            return (httpResponse(status: 400, body: "{\"error\":\"bad_headers\"}"), nil)
        }

        // Parse headers
        var contentLength = 0
        var hookToken: String? = nil
        for line in headerStr.components(separatedBy: "\r\n").dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)) ?? 0
            } else if lower.hasPrefix("x-devdash-token:") {
                hookToken = line.dropFirst("x-devdash-token:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        // Body size cap (#4)
        if contentLength > 1_000_000 {
            return (httpResponse(status: 400, body: "{\"error\":\"too_large\"}"), nil)
        }

        let bodyStart = sepRange.upperBound
        let bodyAvailable = buf.count - (bodyStart - buf.startIndex)
        guard bodyAvailable >= contentLength else { return nil }  // need more

        // Token auth. Plain == is fine here: loopback-only bind + 0600 token file means a timing oracle isn't a meaningful threat.
        lock.lock()
        let storedToken = token
        lock.unlock()
        guard let hookToken, hookToken == storedToken else {
            return (httpResponse(status: 403, body: "{\"error\":\"forbidden\"}"), nil)
        }

        // Decode body
        let bodyData = buf[bodyStart..<(bodyStart + contentLength)]
        guard
            let obj = try? JSONSerialization.jsonObject(with: bodyData),
            let dict = obj as? [String: Any],
            let event = ClaudeHookEvent(json: dict)
        else {
            return (httpResponse(status: 400, body: "{\"error\":\"bad_request\"}"), nil)
        }

        // Async handler dispatch — completion-based, no semaphore (#2)
        let asyncBlock: () -> Void = { [weak self] in
            guard let self else {
                self?.sendAndClose(self?.httpResponse(status: 200, body: "{}") ?? Data(), on: conn)
                return
            }
            guard let handler = self.onEvent else {
                self.sendAndClose(self.httpResponse(status: 200, body: "{}"), on: conn)
                return
            }
            DispatchQueue.main.async {
                handler(event) { [weak self] body in
                    guard let self else { return }
                    self.sendAndClose(self.httpResponse(status: 200, body: body ?? "{}"), on: conn)
                }
            }
        }
        return (nil, asyncBlock)
    }

    private func sendAndClose(_ data: Data, on conn: NWConnection) {
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - HTTP helpers

    private func httpResponse(status: Int, body: String) -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 403: statusText = "Forbidden"
        default:  statusText = "Error"
        }
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status) \(statusText)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n\r\n"
        var resp = Data(header.utf8)
        resp.append(bodyData)
        return resp
    }

    // MARK: - Token + endpoint persistence

    private func resolveToken() -> String {
        if let existing = readEndpointFile(), let t = existing["token"] as? String, !t.isEmpty {
            return t
        }
        return generateToken()
    }

    /// Generate a cryptographically random 32-hex token. (#6)
    /// Falls back to UUID hex if SecRandomCopyBytes fails.
    private func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        // Fallback: two UUIDs concatenated — still high-entropy
        NSLog("[EventServer] SecRandomCopyBytes failed (%d); using UUID fallback", status)
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private func persistEndpoint(port: Int) {
        lock.lock()
        let t = token
        lock.unlock()
        let dict: [String: Any] = ["port": port, "token": t]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) else { return }
        let fm = FileManager.default
        try? data.write(to: endpointFile, options: .atomic)
        // Restrict to owner read/write only — file contains auth token (#5)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpointFile.path)
    }

    private func readEndpointFile() -> [String: Any]? {
        guard let data = try? Data(contentsOf: endpointFile),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return nil }
        return dict
    }
}

// MARK: - Helpers

/// Reference-type box for propagating a Bool mutation through closures
/// without needing `inout` across async boundaries.
private final class RespondedBox {
    var value: Bool
    init(value: Bool) { self.value = value }
}
