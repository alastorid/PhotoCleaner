import Foundation
import Network
import os

/// Minimal, dependency-free HTTP/1.1 server on Network.framework.
///
/// Network.framework is the current Apple-supported transport (CFSocket and
/// friends are deprecated, and an external server dependency would violate the
/// "no third-party runtime" rule). The listener is pinned to `127.0.0.1` and
/// additionally rejects non-local peers, so nothing is ever reachable from the
/// LAN. There is no route to the filesystem: the only bytes served are the
/// embedded UI and images read through PhotoKit.
final class HTTPServer: @unchecked Sendable {
    let port: UInt16
    private let router: Router
    private let queue = DispatchQueue(label: "com.alastorid.photocleaner.http", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var listener: NWListener?
        /// Live connections, retained by the server. Network.framework only
        /// weakly references the objects owning its callbacks, so without this
        /// a connection would be deallocated the moment it was created.
        var connections: [ObjectIdentifier: HTTPConnection] = [:]
    }

    init(port: UInt16, router: Router) {
        self.port = port
        self.router = router
    }

    /// Starts listening and waits until the socket is actually ready to accept.
    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Belt and braces: bind to loopback *and* refuse non-local peers.
        parameters.acceptLocalOnly = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw HTTPError.invalidPort(port)
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] networkConnection in
            guard let self else { networkConnection.cancel(); return }
            let connection = HTTPConnection(connection: networkConnection,
                                            router: self.router,
                                            queue: self.queue)
            let key = ObjectIdentifier(connection)
            connection.onFinish = { [weak self] in
                self?.state.withLock { $0.connections[key] = nil }
            }
            self.state.withLock { $0.connections[key] = connection }
            connection.start()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let shouldResume = resumed.withLock { value -> Bool in
                        defer { value = true }
                        return !value
                    }
                    if shouldResume { continuation.resume() }
                case .failed(let error):
                    let shouldResume = resumed.withLock { value -> Bool in
                        defer { value = true }
                        return !value
                    }
                    if shouldResume { continuation.resume(throwing: error) }
                case .cancelled:
                    let shouldResume = resumed.withLock { value -> Bool in
                        defer { value = true }
                        return !value
                    }
                    if shouldResume { continuation.resume(throwing: HTTPError.cancelled) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
            state.withLock { $0.listener = listener }
        }
    }

    func stop() {
        let connections = state.withLock { current -> [HTTPConnection] in
            current.listener?.cancel()
            current.listener = nil
            return Array(current.connections.values)
        }
        for connection in connections { connection.shutdown() }
    }
}

enum HTTPError: Error, CustomStringConvertible {
    case invalidPort(UInt16)
    case cancelled

    var description: String {
        switch self {
        case .invalidPort(let port): return "invalid port \(port)"
        case .cancelled: return "the listener was cancelled before it became ready"
        }
    }
}

/// One client connection.
///
/// Every mutable field is confined to the shared serial `queue`: Network
/// callbacks arrive there, and the only other writer (a finished request
/// handler) hops back onto it before touching state. Hence `@unchecked`.
private final class HTTPConnection: @unchecked Sendable {
    private static let maxHeaderBytes = 32 * 1024
    private static let maxBodyBytes = 1 * 1024 * 1024
    /// Ceiling on bytes held for requests that have arrived but cannot be parsed
    /// yet. The oversized-header and oversized-body checks both run only when the
    /// buffer is *inspectable*; without an absolute cap a client could pipeline
    /// megabytes into a connection that is parked waiting on a slow handler.
    private static let maxBufferBytes = maxHeaderBytes + maxBodyBytes + 64 * 1024
    private static let idleTimeout: TimeInterval = 20
    private static let requestTimeout: TimeInterval = 120

    private let connection: NWConnection
    private let router: Router
    private let queue: DispatchQueue

    private var buffer = Data()
    private var busy = false
    private var streaming = false
    /// Set once a final response has been written, or the connection is on its way
    /// out. A handler that completes *after* a `408`/error response has already
    /// gone out must not append a second response body to the same connection.
    private var finishing = false
    private var closed = false
    private var idleTimer: DispatchWorkItem?
    private var requestTimer: DispatchWorkItem?
    private var handlerTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var unsubscribe: (@Sendable () -> Void)?

    /// Called exactly once, after the connection has been torn down, so the
    /// server can drop its retain on this object.
    var onFinish: (@Sendable () -> Void)?

    init(connection: NWConnection, router: Router, queue: DispatchQueue) {
        self.connection = connection
        self.router = router
        self.queue = queue
    }

    /// Tears the connection down from outside its own queue.
    func shutdown() {
        queue.async { [weak self] in self?.close(reason: "server stopping") }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        armIdleTimer()
        receive()
    }

    // MARK: - Receive loop

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard !self.closed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                // Only the *idle* timer is disarmed by traffic. Cancelling the
                // request timeout here would silently disable it for any client
                // that pipelines while a handler is running, leaving a hung
                // handler with no deadline and a connection nothing will ever
                // reclaim.
                self.cancelIdleTimer()
                if self.buffer.count > Self.maxBufferBytes {
                    self.respondAndClose(.error("request headers or pipelined data too large", status: 413))
                    return
                }
            }
            if let error {
                self.close(reason: "receive failed: \(error)")
                return
            }
            if isComplete, data?.isEmpty ?? true {
                self.close(reason: "peer closed")
                return
            }
            self.processBuffer()
            guard !self.closed, !self.finishing else { return }
            self.receive()
        }
    }

    // MARK: - Request parsing

    private func processBuffer() {
        guard !closed, !finishing, !streaming, !busy else { return }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHeaderBytes {
                respondAndClose(.error("request headers too large", status: 431))
            } else {
                armIdleTimer()
            }
            return
        }

        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let head = String(data: Data(headerData), encoding: .utf8) else {
            respondAndClose(.error("malformed request headers", status: 400))
            return
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            respondAndClose(.error("malformed request line", status: 400))
            return
        }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength >= 0, contentLength <= Self.maxBodyBytes else {
            respondAndClose(.error("request body too large", status: 413))
            return
        }

        let bodyStart = buffer.distance(from: buffer.startIndex, to: headerEnd.upperBound)
        guard buffer.count - bodyStart >= contentLength else {
            armIdleTimer()  // body still arriving
            return
        }

        let body = Data(buffer[(buffer.startIndex + bodyStart)..<(buffer.startIndex + bodyStart + contentLength)])
        buffer.removeFirst(bodyStart + contentLength)
        if buffer.startIndex != 0 { buffer = Data(buffer) }

        let keepAlive = Self.shouldKeepAlive(version: parts.count > 2 ? String(parts[2]) : "HTTP/1.1",
                                             headers: headers)
        let request = Self.makeRequest(method: method, target: target, headers: headers, body: body)

        busy = true
        armRequestTimer()
        let router = self.router
        handlerTask = Task { [weak self] in
            let result = await router.handle(request)
            guard let self else { return }
            self.queue.async { self.deliver(result, keepAlive: keepAlive) }
        }
    }

    private static func shouldKeepAlive(version: String, headers: [String: String]) -> Bool {
        let connectionHeader = headers["connection"]?.lowercased()
        if connectionHeader == "close" { return false }
        if version.contains("1.0") { return connectionHeader == "keep-alive" }
        return true
    }

    private static func makeRequest(method: String, target: String, headers: [String: String], body: Data) -> HTTPRequest {
        let rawPath: String
        var queryItems: [String: String] = [:]
        if let questionMark = target.firstIndex(of: "?") {
            rawPath = String(target[target.startIndex..<questionMark])
            let queryString = String(target[target.index(after: questionMark)...])
            for pair in queryString.split(separator: "&") {
                // Query names and values follow the form-urlencoded rules, where
                // `+` is a space.
                guard let equals = pair.firstIndex(of: "=") else {
                    queryItems[String(pair).percentDecodedQueryValue] = ""
                    continue
                }
                let name = String(pair[pair.startIndex..<equals]).percentDecodedQueryValue
                let value = String(pair[pair.index(after: equals)...]).percentDecodedQueryValue
                queryItems[name] = value
            }
        } else {
            rawPath = target
        }
        // Path components do *not* follow the form-urlencoded rules: a `+` in a
        // path is a literal plus, so it gets the path decoder. Decoding after
        // the split is what allows a Photos `localIdentifier` (which contains
        // slashes) to arrive as one `%2F`-escaped segment.
        let segments = rawPath.split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).percentDecodedPathSegment }
        return HTTPRequest(method: method, rawPath: rawPath, segments: segments,
                           query: queryItems, headers: headers, body: body)
    }

    // MARK: - Responding

    private func deliver(_ result: RouteResult, keepAlive: Bool) {
        guard !closed, !finishing else { return }
        switch result {
        case .response(let response):
            busy = false
            cancelTimers()
            send(response, keepAlive: keepAlive)
        case .stream(let stream):
            busy = false
            cancelTimers()
            beginStream(stream)
        }
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool) {
        var header = "HTTP/1.1 \(response.status) \(HTTPStatus.text(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = keepAlive ? "keep-alive" : "close"
        headers["X-Content-Type-Options"] = "nosniff"
        headers["Referrer-Policy"] = "no-referrer"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            header += "\(name): \(value)\r\n"
        }
        header += "\r\n"

        var payload = Data(header.utf8)
        payload.append(response.body)

        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.close(reason: "send failed: \(error)")
                    return
                }
                if keepAlive {
                    self.armIdleTimer()
                    self.processBuffer()
                } else {
                    self.close(reason: "response sent")
                }
            }
        })
    }

    private func respondAndClose(_ response: HTTPResponse) {
        busy = false
        cancelTimers()
        // Latched before the write, not after: the handler this is racing with
        // finishes on the same queue and would otherwise write its own response
        // into a connection that is already answering.
        finishing = true
        // …and latching is not enough on its own, because `beginStream` has
        // already written a `200` status line and switched this connection to
        // chunked transfer encoding. Writing `response` here would put a second
        // HTTP response — headers, status line and all — into the middle of a
        // live event stream: two responses on one connection, which is the
        // response-splitting shape `finishing` exists to prevent, reached through
        // the one code path that was supposed to be safe. `413` and `408` both
        // land here, and a client that uploads ~1 MB to `/api/events` reaches
        // them.
        //
        // There is nothing left to say in HTTP terms, so the stream is ended
        // properly instead: the terminating zero-length chunk, then the close
        // that unsubscribes from the EventBus. The client sees a truncated event
        // stream, which is honest, instead of a spliced `413`.
        if streaming {
            finishStream()
            return
        }
        send(response, keepAlive: false)
    }

    // MARK: - Server-Sent Events

    private func beginStream(_ stream: HTTPStream) {
        var header = "HTTP/1.1 200 OK\r\n"
        var headers = stream.headers
        headers["Transfer-Encoding"] = "chunked"
        headers["Connection"] = "keep-alive"
        headers["Cache-Control"] = "no-cache, no-transform"
        headers["X-Content-Type-Options"] = "nosniff"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            header += "\(name): \(value)\r\n"
        }
        header += "\r\n"
        streaming = true
        unsubscribe = stream.onClose

        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard error == nil, !self.closed, !self.finishing else {
                    // Tear the connection down rather than leaving it open with no
                    // reader: `close()` is what calls `unsubscribe`, so bailing
                    // out here would leak both the socket and this subscriber's
                    // continuation in the EventBus for the life of the process.
                    self.close(reason: "stream header send failed: \(error.map { "\($0)" } ?? "closed")")
                    return
                }
                self.streamTask = Task { [weak self] in
                    for await event in stream.events {
                        guard let self else { return }
                        self.queue.async { self.writeChunk(event) }
                    }
                    guard let self else { return }
                    self.queue.async { self.finishStream() }
                }
            }
        })
    }

    private func writeChunk(_ payload: Data) {
        guard !closed, streaming else { return }
        var frame = Data(String(payload.count, radix: 16).utf8)
        frame.append(contentsOf: "\r\n".utf8)
        frame.append(payload)
        frame.append(contentsOf: "\r\n".utf8)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.queue.async { self.close(reason: "stream send failed: \(error)") }
        })
    }

    private func finishStream() {
        guard !closed, streaming else { return }
        connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.close(reason: "stream finished") }
        })
    }

    // MARK: - Timers and teardown

    private func armIdleTimer() {
        guard !closed, !finishing, !streaming, !busy else { return }
        idleTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.close(reason: "idle timeout")
        }
        idleTimer = work
        queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: work)
    }

    private func armRequestTimer() {
        requestTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.busy, !self.finishing else { return }
            self.busy = false
            self.respondAndClose(.error("the request took too long", status: 408))
        }
        requestTimer = work
        queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: work)
    }

    private func cancelIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    private func cancelTimers() {
        cancelIdleTimer()
        requestTimer?.cancel()
        requestTimer = nil
    }

    private func close(reason: String = "") {
        guard !closed else { return }
        closed = true
        finishing = true
        cancelTimers()
        handlerTask?.cancel()
        streamTask?.cancel()
        handlerTask = nil
        streamTask = nil
        unsubscribe?()
        unsubscribe = nil
        connection.cancel()
        let finish = onFinish
        onFinish = nil
        finish?()
    }
}
