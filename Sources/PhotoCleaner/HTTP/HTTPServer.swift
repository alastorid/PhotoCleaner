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
    /// Set once the terminating zero-length chunk has been handed to Network.
    /// After that the body is over: a frame that was already in flight when the
    /// stream ended must not be written *behind* the terminator, and the
    /// terminator must not be written a second time.
    private var streamEnded = false
    /// Set once a final response has been written, or the connection is on its way
    /// out. A handler that completes *after* a `408`/error response has already
    /// gone out must not append a second response body to the same connection.
    private var finishing = false
    private var closed = false
    /// The peer has said it will send nothing more (a half-close). Distinct from
    /// `closed`: the response still owed on this connection has not gone out yet.
    private var peerClosed = false
    private var idleTimer: DispatchWorkItem?
    private var requestTimer: DispatchWorkItem?
    private var handlerTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var unsubscribe: (@Sendable () -> Void)?
    /// The file body currently being written, if any. Its presence is what keeps
    /// `busy` true for the whole body, and `close()` drops the descriptor through it.
    private var fileBody: FileBody?
    /// Chunk size for a streamed file body.
    ///
    /// 512 KB. Two reasons, and they pull in the same direction. Large enough that a
    /// 2 GB clip is ~4,000 writes rather than one per 8 KB, which matters because
    /// every write is a completion handler and a queue hop. Small enough that the
    /// read between two writes is bounded work: the file is never read in one call on
    /// the connection queue, so a slow client throttles *this* response instead of
    /// every other connection — the same reason the thumbnail path is off-actor.
    private static let fileChunkBytes = 512 * 1024

    /// One in-flight file body: the descriptor, how much of it is left, and the
    /// keep-alive decision the final chunk will act on.
    ///
    /// A separate object rather than three fields on the connection because the write
    /// chain is a recursion through `connection.send`'s completion handler, and what
    /// it needs to carry — which body, how many bytes remain — has to survive each
    /// hop without the connection itself looking like it is mid-download at all.
    private final class FileBody: @unchecked Sendable {
        let handle: FileHandle
        /// Bytes still to write. Decremented by what was *actually* read, not by what
        /// was asked for: a short read is normal near the end of a file and must not
        /// be allowed to end the body early with the announced length unmet.
        var remaining: Int64
        let keepAlive: Bool
        /// Latched when the last chunk has been written and the connection has been
        /// released. Not inferred from `remaining`, for the same reason `streamEnded`
        /// exists: the chain can arrive at the end twice — once from the final chunk's
        /// completion, once from a read that found EOF — and the keep-alive re-arm
        /// must happen exactly once. Two re-arms corrupt the next response on this
        /// connection.
        var finished = false

        /// Written out because a memberwise initialiser for a nested type in a
        /// `private` class is itself `private` to the file scope in a way that reads
        /// like an accident rather than a decision — and this constructor is a
        /// decision: the invariant is that `remaining` starts as the *whole* announced
        /// length, so there is no way to build a body that promises one length and
        /// writes another.
        init(handle: FileHandle, remaining: Int64, keepAlive: Bool) {
            self.handle = handle
            self.remaining = remaining
            self.keepAlive = keepAlive
        }
    }

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
            if isComplete {
                // The peer will send nothing more. That is *not* the same as it
                // wanting nothing back: a client that half-closes its write side
                // after a request still expects the response, and closing here
                // would cancel the handler mid-flight and drop it. The connection
                // is therefore only marked, and torn down by whichever path gets
                // there last — `send` once the answer is out, or immediately if
                // there was nothing in flight to answer.
                self.peerClosed = true
                self.processBuffer()
                guard !self.closed, !self.finishing else { return }
                if !self.busy, !self.streaming, self.buffer.isEmpty {
                    self.close(reason: "peer closed")
                }
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
        /// Collected separately from `headers` because that dictionary keeps one
        /// value per name, and a repeated `Content-Length` is exactly the case
        /// that must not be collapsed to "the last one".
        var contentLengths: [String] = []
        for line in lines where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<separator]
            // RFC 9112 §5.1 allows no whitespace between a field name and its
            // colon, and tolerating some of it is how two readers of the same
            // request disagree about where the name ends. Refused rather than
            // trimmed, because the trimmed reading is the dangerous one.
            guard !name.isEmpty, !name.contains(where: \.isWhitespace) else {
                respondAndClose(.error("malformed header field name", status: 400))
                return
            }
            let field = name.lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[field] = value
            if field == "content-length" { contentLengths.append(value) }
        }

        // Request framing is read exactly once, here, and a request whose framing
        // cannot be read is refused rather than guessed at — the guess is what
        // desynchronises a connection.
        //
        // `Transfer-Encoding` is not implemented at all, and ignoring it is the
        // plainest form of the hazard: a chunked body would be read as zero bytes
        // here and then parsed as the *next* request off this connection. RFC 9112
        // §6.1 requires a server that does not implement a coding to say so.
        if let coding = headers["transfer-encoding"] {
            respondAndClose(.error(
                "unsupported transfer coding \"\(coding)\"; this server reads Content-Length bodies only",
                status: 400))
            return
        }
        // Two `Content-Length` headers are either the same number twice (harmless
        // but pointless) or two different numbers, and a server that picks one is
        // a server a front end can disagree with. RFC 9112 §6.3.
        guard contentLengths.count <= 1 else {
            respondAndClose(.error("more than one Content-Length header", status: 400))
            return
        }
        var contentLength = 0
        if let raw = contentLengths.first {
            // Not `?? 0`: a length that is not a length leaves the body in the
            // buffer to be read as another request, which is the same hazard again.
            guard let parsed = Int(raw), parsed >= 0 else {
                respondAndClose(.error("malformed Content-Length", status: 400))
                return
            }
            contentLength = parsed
        }
        guard contentLength <= Self.maxBodyBytes else {
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
        // `HEAD` is `GET` with the body dropped on the way out, so it is routed as
        // a `GET` and answered by `send` with the body suppressed. Routed as
        // anything else it would 404, and a `HEAD` that 404s a route the server
        // happily serves is a worse answer than no `HEAD` support at all: it tells
        // a client the resource does not exist.
        let headOnly = method == "HEAD"
        let request = Self.makeRequest(method: headOnly ? "GET" : method,
                                       target: target, headers: headers, body: body)

        busy = true
        // The idle deadline is for a connection with *nothing* to do. Handing a
        // request to a handler is the opposite of that, and the two deadlines are
        // deliberately different lengths (20 s against 120 s), so an idle timer
        // left armed here would reclaim the connection out from under a handler
        // that had not yet come close to its own timeout. The path that made this
        // reachable is `send`'s completion, which arms the idle timer and *then*
        // calls `processBuffer` to dispatch a pipelined request.
        cancelIdleTimer()
        armRequestTimer()
        let router = self.router
        handlerTask = Task { [weak self] in
            let result = await router.handle(request)
            guard let self else { return }
            self.queue.async { self.deliver(result, keepAlive: keepAlive, headOnly: headOnly) }
        }
    }

    /// `Connection` is a *list* of tokens (RFC 9110 §7.6.1), not one value, and the
    /// options a client sends alongside the one that matters are common —
    /// `Connection: keep-alive, close` is what some HTTP/1.1 clients emit when they
    /// mean to close. Comparing the whole string to `"close"` therefore missed it
    /// and kept the connection open past the client's own last request.
    private static func connectionTokens(_ headers: [String: String]) -> Set<String> {
        guard let raw = headers["connection"] else { return [] }
        return Set(raw.lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    private static func shouldKeepAlive(version: String, headers: [String: String]) -> Bool {
        let tokens = connectionTokens(headers)
        if tokens.contains("close") { return false }
        if version.contains("1.0") { return tokens.contains("keep-alive") }
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

    private func deliver(_ result: RouteResult, keepAlive: Bool, headOnly: Bool = false) {
        // A stream that is dropped here has already subscribed — `Router.events`
        // subscribes *before* it returns the `HTTPStream`, because the subscriber
        // has to be registered before the snapshot is taken or a publish in
        // between would be missed. Returning without releasing it would leave a
        // continuation in the EventBus for a connection that no longer exists,
        // and every publish would keep yielding into it for the life of the
        // process.
        guard !closed, !finishing else {
            if case .stream(let stream) = result { stream.onClose() }
            return
        }
        switch result {
        case .response(let response):
            busy = false
            cancelTimers()
            send(response, keepAlive: keepAlive, headOnly: headOnly)
        case .file(let file):
            // `busy` stays true for the whole body. Nothing else on this connection
            // may run while a response is half-written: `processBuffer` would
            // otherwise dispatch a pipelined request the moment a byte arrived, and
            // its response would be interleaved into the middle of this body. It is
            // the same thing `streaming` does for an event stream, reached by the
            // other door — which is why `respondAndClose`'s chunked-teardown branch
            // must not be reused here.
            cancelTimers()
            // A `HEAD` on a video must answer with the headers a `GET` would have
            // produced — including the *range* `Content-Length`, which is the number
            // a client sizes its buffer from — and no body at all (RFC 9110 §9.3.2).
            // Sending the body anyway desynchronises the connection: a `HEAD` client
            // reads none of it and treats the next `Content-Length` bytes as the
            // following response.
            send(file, keepAlive: keepAlive, headOnly: headOnly)
        case .stream(let stream):
            busy = false
            cancelTimers()
            if headOnly {
                // A `HEAD` must not open a long-lived connection to a stream it
                // is never going to read: it is answered with the headers the
                // stream would have sent and then closed, which is the whole of
                // what `HEAD` is allowed to do.
                var headers = stream.headers
                headers["Content-Length"] = "0"
                unsubscribe = stream.onClose
                unsubscribe?()
                unsubscribe = nil
                send(HTTPResponse(status: 200, headers: headers),
                     keepAlive: false, headOnly: true)
                return
            }
            beginStream(stream)
        }
    }

    /// The header block for one response, as bytes.
    ///
    /// One builder for both response paths, and the reason is `Content-Length`. That
    /// header is a *claim about framing*, so it must come from the same place that
    /// knows what is going to be written: `contentLength` is the number of body bytes
    /// this response will carry, and nil means "announce nothing" — which is the
    /// correct answer for a status that cannot carry a body at all (RFC 9110 §8.6), and
    /// was the only header saying so on `/favicon.ico`.
    ///
    /// Getting this wrong is silent and severe. A file range whose length came from an
    /// empty `HTTPResponse.body` announces `Content-Length: 0` for a 4 GB clip, and the
    /// client waits out a body that never comes; the reverse — announcing the whole
    /// file for a `206` — leaves the client reading the next response's bytes as the
    /// tail of this one. So the number is a parameter with one meaning, not something
    /// a caller can set in a header dictionary and have overwritten.
    ///
    /// The security headers are added here rather than at the call sites so that a new
    /// response path cannot ship without them — which is the same argument the SSE
    /// header block makes, and the reason it is not shared with this one (it declares
    /// chunked framing, which is not a decision this function makes).
    private static func headerBytes(status: Int, headers: [String: String],
                                    contentLength: Int?, keepAlive: Bool) -> Data {
        var header = "HTTP/1.1 \(status) \(HTTPStatus.text(status))\r\n"
        var fields = headers
        if let contentLength { fields["Content-Length"] = String(contentLength) }
        fields["Connection"] = keepAlive ? "keep-alive" : "close"
        fields["X-Content-Type-Options"] = "nosniff"
        fields["Referrer-Policy"] = "no-referrer"
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            header += "\(name): \(value)\r\n"
        }
        header += "\r\n"
        return Data(header.utf8)
    }

    /// Writes one complete response.
    ///
    /// `headOnly` suppresses the body of a `HEAD` reply while keeping the
    /// `Content-Length` the matching `GET` would have sent — RFC 9110 §9.3.2:
    /// the headers must be the ones `GET` produces, and the body is the only
    /// thing that is dropped. Sending the body anyway desynchronises the
    /// connection, because a `HEAD` client reads no body and treats the next
    /// `Content-Length` bytes as the following response.
    private func send(_ response: HTTPResponse, keepAlive: Bool, headOnly: Bool = false) {
        // A status that cannot carry a body must not announce a length either.
        let canCarryBody = response.status != 204 && response.status != 304
            && !(100...199).contains(response.status)
        var payload = Self.headerBytes(status: response.status, headers: response.headers,
                                       contentLength: canCarryBody ? response.body.count : nil,
                                       keepAlive: keepAlive)
        if !headOnly { payload.append(response.body) }

        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.close(reason: "send failed: \(error)")
                    return
                }
                self.releaseConnection(keepAlive: keepAlive, reason: "response sent")
            }
        })
    }

    /// Writes a response whose body is a byte range of a file on disk, then feeds the
    /// file to the connection in chunks.
    ///
    /// Separate from `send(_:keepAlive:headOnly:)` rather than a flag on it, because
    /// the two differ in something structural: an in-memory response is one
    /// `connection.send` of header-plus-body and is over when it returns, while this
    /// one is a *sequence* of writes whose intermediate states must not be observable
    /// to anything else on the connection. Merging them would mean one function with
    /// three notions of "finished".
    ///
    /// The failures this shape exists to avoid, all of them silent:
    ///
    /// - The file is opened **before** the headers go out, so a missing or
    ///   unopenable export is a `404`/`500` rather than a `200` promising N bytes of
    ///   a file that was never there — which the client would wait out to the last
    ///   one.
    /// - The descriptor is dropped after the last chunk. `FileHandle` is not
    ///   reference-counted into oblivion and a leaked one per playback is a file
    ///   descriptor leak in a process that also holds a PhotoKit cache.
    /// - `headOnly` writes the headers and stops. Same `Content-Length` the `GET`
    ///   would have announced, no body (RFC 9110 §9.3.2).
    private func send(_ file: HTTPFile, keepAlive: Bool, headOnly: Bool = false) {
        // The header block is built once and used by both exits below. `Content-Length`
        // is the range length — never `HTTPResponse.body.count`, which for a file body
        // is 0 by construction, and never the file's size, which would be wrong for a
        // `206`. `Int(...)` is exact here because a 32-bit `Int` cannot hold a 2 GB
        // clip and this app is 64-bit only (`build.sh` builds arm64/x86_64).
        let header = Self.headerBytes(status: file.status, headers: file.headers,
                                      contentLength: Int(file.length), keepAlive: keepAlive)

        // A `HEAD`, or a range that is empty because the file is empty. Both are
        // "headers, no body", and both are complete responses as they stand — the
        // keep-alive re-arm is the same single one the in-memory path performs.
        guard !headOnly, file.length > 0 else {
            connection.send(content: header, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    if let error {
                        self.close(reason: "send failed: \(error)")
                        return
                    }
                    self.releaseConnection(keepAlive: keepAlive, reason: "response sent")
                }
            })
            return
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file.url)
        } catch {
            // Nothing has been written yet, so this is still a well-formed connection
            // and an honest status is available. `send` it as a normal response rather
            // than closing: the client's next request on a keep-alive connection
            // should not have to reconnect because one video vanished from the export
            // cache underneath it.
            send(.error("the exported clip is no longer on disk", status: 404), keepAlive: keepAlive)
            return
        }
        do {
            // Seeking is what makes a `206` mean anything: without it every seek would
            // be answered with the head of the clip, which decodes as a frozen frame
            // rather than as an error.
            try handle.seek(toOffset: UInt64(file.start))
        } catch {
            try? handle.close()
            send(.error("could not read the exported clip", status: 500), keepAlive: keepAlive)
            return
        }

        let body = FileBody(handle: handle, remaining: file.length, keepAlive: keepAlive)
        fileBody = body
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self else {
                try? handle.close()
                return
            }
            self.queue.async {
                if let error {
                    self.close(reason: "send failed: \(error)")
                    return
                }
                self.writeChunk(body)
            }
        })
    }

    /// Writes the next chunk of an in-flight file body and chains the one after it.
    ///
    /// The recursion is through `connection.send`'s completion handler, not a loop,
    /// and that is the load-bearing part: a loop would read and buffer the whole file
    /// on the connection queue while the socket drained, which is precisely the
    /// "one blocking read on the shared queue" this route must not do. Each read is
    /// bounded to `fileChunkBytes` and happens after the previous write has been
    /// accepted, so the queue is idle for as long as the client is slow.
    private func writeChunk(_ body: FileBody) {
        // Re-checked at every hop rather than only at the start of the chain. A body
        // can be seconds long, and in that window the connection can be closed by the
        // client disconnecting, by `shutdown()`, or by a `413` for data the client
        // pipelined behind its video request. A chain that outlived its connection
        // would keep reading a file for nobody, and would call `releaseConnection` on
        // a connection whose socket has already been cancelled — which re-arms the
        // keep-alive timer and dispatches whatever is in the buffer to a dead socket.
        //
        // The idle and request timers are *not* in that list because `busy` stays true
        // for the whole body and both of them are gated on it being false; that is the
        // other half of why it does.
        guard !closed, !finishing, !body.finished else { return }
        guard body.remaining > 0 else { finishFileBody(body); return }

        let want = Int(min(body.remaining, Int64(Self.fileChunkBytes)))
        let chunk: Data
        do {
            guard let data = try body.handle.read(upToCount: want), !data.isEmpty else {
                // Short read or EOF before the announced `Content-Length`. Writing
                // what we have would be the worst outcome available: the client is
                // inside a body it has been told the length of, so a truncated one
                // leaves it waiting on a connection that has nothing more to send —
                // and the next response's bytes get read as the rest of this one.
                // Closing is the only honest signal.
                Log.warn("video stream ended \(body.remaining) bytes early; closing the connection")
                close(reason: "video body truncated")
                return
            }
            chunk = data
        } catch {
            // A read error mid-body is the same situation as a truncated read and gets
            // the same answer, for the same reason.
            Log.warn("video stream read failed: \(error); closing the connection")
            close(reason: "video body read failed")
            return
        }
        body.remaining -= Int64(chunk.count)

        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                // A send error here is the client having gone away mid-body. Ending
                // the chain is the whole handling: without the `error` check the next
                // `writeChunk` would run, and then the next, each failing immediately
                // — a spin that would burn a core for as long as the file is long.
                if let error {
                    self.close(reason: "send failed: \(error)")
                    return
                }
                self.writeChunk(body)
            }
        })
    }

    /// The last chunk is out: drop the descriptor and release the connection, once.
    private func finishFileBody(_ body: FileBody) {
        guard !body.finished else { return }
        // Latched before the release, so a late hop cannot release twice.
        body.finished = true
        if fileBody === body { fileBody = nil }
        try? body.handle.close()
        releaseConnection(keepAlive: body.keepAlive, reason: "response sent")
    }

    /// Hands the connection back to the keep-alive machinery, or closes it.
    ///
    /// Extracted from `send(_:keepAlive:headOnly:)` because the file path reaches
    /// exactly the same decision at a different time — after the final chunk rather
    /// than after a single write — and the two re-armings must be the same *one*
    /// re-arming, not two implementations that drift.
    private func releaseConnection(keepAlive: Bool, reason: String) {
        busy = false
        if keepAlive && !peerClosed {
            armIdleTimer()
            processBuffer()
        } else {
            close(reason: reason)
        }
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
        //
        // A file body gets the third answer: the close, with nothing written. A
        // `413`/`431` here means a client pipelined megabytes *behind* a video
        // request, and by the time it is answered the status line and most of the
        // body are already on the wire — a second response spliced into the middle of
        // a `Content-Length`-framed body is unreadable as anything, and worse than
        // the truncation, because the client will not know it is truncated. The
        // chunked terminator is no help either: that framing is not what this
        // response declared. So the connection ends and the client sees a short body,
        // which it must already handle for every dropped connection.
        if fileBody != nil {
            close(reason: "error during a file body")
            return
        }
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
        // `streamEnded` and not just `streaming`: once the terminating
        // zero-length chunk has gone out, anything still queued behind it would
        // be read by the client as the start of a *second* response body.
        guard !closed, streaming, !streamEnded else { return }
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
        guard !closed, streaming, !streamEnded else { return }
        // Latched before the write, and `close()` does not clear it either — the
        // terminator is a framing artefact, and exactly one of them may appear in
        // a response. `respondAndClose` and the end of the event stream can both
        // reach this method for the same connection.
        streamEnded = true
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
            // Re-checked rather than trusted: the timer is armed optimistically
            // and `busy` can become true between arming and firing, in which case
            // the request timeout owns the connection and this must not take it.
            guard let self, !self.closed, !self.finishing, !self.streaming, !self.busy else { return }
            self.close(reason: "idle timeout")
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
        // A file body in flight goes with the connection. `closed` is latched before
        // this, so the write chain's next hop returns at its guard rather than
        // resurrecting a connection whose socket has just been cancelled — and the
        // descriptor is released here rather than waiting for a completion that may
        // never come, since the send it was waiting on is the one being torn down.
        try? fileBody?.handle.close()
        fileBody = nil
        unsubscribe?()
        unsubscribe = nil
        connection.cancel()
        let finish = onFinish
        onFinish = nil
        finish?()
    }
}
