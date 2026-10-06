import Foundation

// The HTTP connection, end to end.
//
// `HTTPConnection` is `private`, so its parser cannot be called directly. Rather
// than re-implement it in the tests — a test that re-implements the logic it is
// testing is worse than no test — the server is started on a real loopback socket
// with a real `Router` and driven with real bytes. Every assertion below is about
// the production parser, the production response writer and the production timers.
//
// No network is involved: the listener is bound to 127.0.0.1 and the client is a
// plain TCP socket to that address. No route used here can delete anything: the
// only POST is `/api/selection/preview` with an empty identifier list.

func registerHTTPServerTests() {
    let suite = "HTTP connection"

    // MARK: a well-formed response

    Registry.shared.add(suite: suite, TestCase(name: "a GET gets one complete, well-formed response",
        knownBug: nil) {
        try await withServer { server in
            try await server.write("""
            GET /api/photos?lo=-1&hi=1&limit=2 HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            Connection: close\r
            \r

            """)
            let response = checkNotNil(try await server.readResponse(), "a response")
            checkEqual(response?.status, 200, "status line")
            checkEqual(response?.reason, "OK", "reason phrase agrees with the code")
            checkEqual(response?.header("content-length").flatMap { Int($0) }, response?.body.count,
                       "Content-Length matches the body exactly")
            checkEqual(response?.header("connection"), "close", "Connection: close is honoured")
            checkEqual(response?.header("x-content-type-options"), "nosniff", "nosniff")
            checkEqual(response?.header("referrer-policy"), "no-referrer", "no-referrer")
            check((response?.header("content-type") ?? "").hasPrefix("application/json"), "content type")
            checkNil(try await server.readOptionalResponse(), "and exactly one response on the connection")
        }
    })

    // MARK: keep-alive and pipelining

    Registry.shared.add(suite: suite, TestCase(name: "keep-alive: three requests on one connection, in order",
        knownBug: nil) {
        try await withServer { server in
            for index in 1...3 {
                try await server.write("""
                GET /api/photos?limit=\(index) HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                \r

                """)
            }
            var sizes: [Int] = []
            for _ in 1...3 {
                let response = checkNotNil(try await server.readResponse(), "response \(sizes.count + 1)")
                checkEqual(response?.status, 200, "status")
                checkEqual(response?.header("connection"), "keep-alive", "the connection stays open")
                let json = response.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
                sizes.append((json?["items"] as? [Any])?.count ?? -1)
            }
            checkEqual(sizes, [1, 2, 3], "each request is answered separately and in order")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "pipelined requests get one response each, in order",
        knownBug: nil) {
        try await withServer { server in
            // Two requests in a single write, which is what pipelining is.
            try await server.write("""
            GET /api/photos?limit=2 HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            \r
            GET /favicon.ico HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            Connection: close\r
            \r

            """)
            let first = checkNotNil(try await server.readResponse(), "the first response")
            let second = checkNotNil(try await server.readResponse(), "the second response")
            checkEqual(first?.status, 200, "the first response")
            checkEqual(first?.header("connection"), "keep-alive", "which keeps the connection alive")
            checkEqual(second?.status, 204, "the second response")
            checkEqual(second?.header("connection"), "close", "which closes it")
            checkEqual(second?.body.count, 0, "and 204 carries no body")
            checkNil(try await server.readOptionalResponse(), "and there is no third response to two requests")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "HTTP/1.0 without keep-alive is answered once and closed",
        knownBug: nil) {
        try await withServer { server in
            try await server.write("""
            GET /favicon.ico HTTP/1.0\r
            Host: 127.0.0.1:\(server.port)\r
            \r

            """)
            let first = checkNotNil(try await server.readResponse(), "the response")
            checkEqual(first?.status, 204, "status")
            checkEqual(first?.header("connection"), "close", "HTTP/1.0 defaults to close")
            checkNil(try await server.readOptionalResponse(), "and the connection is gone")

            try await server.reconnect()
            try await server.write("""
            GET /favicon.ico HTTP/1.0\r
            Host: 127.0.0.1:\(server.port)\r
            Connection: keep-alive\r
            \r
            GET /favicon.ico HTTP/1.0\r
            Host: 127.0.0.1:\(server.port)\r
            \r

            """)
            checkEqual(try await server.readResponse()?.status, 204, "first")
            checkEqual(try await server.readResponse()?.status, 204, "second, on the kept-alive connection")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a lowercase method and mixed-case headers are accepted",
        knownBug: nil) {
        try await withServer { server in
            try await server.write("""
            get /favicon.ico HTTP/1.1\r
            hOsT: 127.0.0.1:\(server.port)\r
            connection: CLOSE\r
            \r

            """)
            let response = checkNotNil(try await server.readResponse(), "the response")
            checkEqual(response?.status, 204, "a lowercase method is upper-cased")
            checkEqual(response?.header("connection"), "close",
                       "and a mixed-case Connection value is lower-cased")
            checkNil(try await server.readOptionalResponse(), "which closed the connection")
        }
    })

    // MARK: caps

    Registry.shared.add(suite: suite, TestCase(name: "oversized headers are refused with 431", knownBug: nil) {
        try await withServer { server in
            // 40 KB of header lines and never the blank line that ends them.
            var request = "GET /api/photos HTTP/1.1\r\n"
            let filler = String(repeating: "x", count: 200)
            while request.utf8.count < 40_000 { request += "x-pad: \(filler)\r\n" }
            try await server.write(request)
            let response = checkNotNil(try await server.readResponse(), "the refusal")
            checkEqual(response?.status, 431, "the connection is answered with 431")
            check(response?.bodyString.contains("headers too large") == true,
                  "and says why: \(response?.bodyString ?? "")")
            checkEqual(response?.header("connection"), "close", "the connection is closed")
            checkNil(try await server.readOptionalResponse(), "with nothing after it")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a Content-Length over 1 MB is refused with 413", knownBug: nil) {
        try await withServer { server in
            try await server.write("""
            POST /api/selection/preview HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            Content-Type: application/json\r
            Content-Length: 2000000\r
            \r

            """)
            let response = checkNotNil(try await server.readResponse(), "the refusal")
            checkEqual(response?.status, 413, "an oversized Content-Length is refused before the body is read")
            check(response?.bodyString.contains("body too large") == true,
                  "and says why: \(response?.bodyString ?? "")")
            checkNil(try await server.readOptionalResponse(), "with nothing after it")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a body just under the ceiling is parsed", knownBug: nil) {
        try await withServer { server in
            let padding = String(repeating: "p", count: 1_000_000)
            let body = #"{"mode":"ids","ids":[],"pad":"\#(padding)"}"#
            check(body.utf8.count <= 1 << 20, "the fixture body is inside the ceiling: \(body.utf8.count)")
            try await server.write("""
            POST /api/selection/preview HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            Content-Type: application/json\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """)
            let response = checkNotNil(try await server.readResponse(), "the response")
            checkEqual(response?.status, 200, "a ~1 MB body is accepted")
            let json = response.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
            checkEqual(json?["mode"] as? String, "ids", "and decoded")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a stream that is then flooded gets no second response",
        knownBug: nil) {
        // `receive()` answers the buffer ceiling with `respondAndClose`, which
        // latches `finishing` and used to write a whole HTTP response — on a
        // connection that had already written a `200` status line and switched to
        // chunked transfer encoding (`beginStream`). A client that sent more than
        // `maxBufferBytes` on an `/api/events` connection therefore got a `413`
        // spliced into the middle of its event stream: two responses on one
        // connection, which is the shape response splitting takes. `respondAndClose`
        // now consults `streaming` and ends the stream instead.
        //
        // Asserted on the raw bytes rather than through the response parser,
        // because the parser is the thing that would have to understand a spliced
        // response in order to notice it: what matters is that no second status
        // line is ever written, and that the stream is ended properly instead.
        try await withServer { server in
            try await server.write("""
            GET /api/events HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            Accept: text/event-stream\r
            \r

            """)
            let header = checkNotNil(try await server.readHeader(), "the stream header")
            checkEqual(header?.status, 200, "the stream starts")
            _ = try await server.readChunk()

            // Now flood the same connection: 1.3 MB, well past the 1.06 MB
            // `maxBufferBytes` ceiling.
            try await server.write(String(repeating: "z", count: 1_300_000))
            let tail = try await server.readRaw(afterSeconds: 4)
            let text = String(decoding: tail, as: UTF8.self)
            check(!text.contains("HTTP/1.1"),
                  "no second status line is written into a stream that already answered, got: \(text.prefix(80).debugDescription)")
            check(!text.contains("413"),
                  "and no refusal status is spliced into the event stream")
            check(text.contains("0\r\n\r\n"),
                  "the stream is ended with a proper zero-length chunk instead")
            let afterwards = try await server.readRaw(afterSeconds: 3)
            check(afterwards.isEmpty,
                  "and nothing at all follows it: \(String(decoding: afterwards, as: UTF8.self).prefix(80).debugDescription)")
        }
    })

    // MARK: exactly one response per connection

    Registry.shared.add(suite: suite, TestCase(name: "exactly one response is ever written per connection",
        knownBug: nil) {
        // Every one of these is a request the connection answers *and closes*, with a
        // second request pipelined behind it. If the parser or the writer ever
        // answered both, the second response would be read by a client that had
        // already been told the connection was over.
        try await withServer { server in
            let hostile: [(name: String, bytes: String)] = [
                ("a request line with no target", "GET\r\n\r\nGET /favicon.ico HTTP/1.1\r\nHost: x\r\n\r\n"),
                ("an empty request line", "\r\n\r\nGET /favicon.ico HTTP/1.1\r\nHost: x\r\n\r\n"),
                ("oversized Content-Length", """
                POST /api/selection/preview HTTP/1.1\r
                Host: x\r
                Content-Length: 99999999\r
                \r
                GET /favicon.ico HTTP/1.1\r
                Host: x\r
                \r

                """),
                ("a negative Content-Length", """
                POST /api/selection/preview HTTP/1.1\r
                Host: x\r
                Content-Length: -1\r
                \r
                GET /favicon.ico HTTP/1.1\r
                Host: x\r
                \r

                """),
            ]
            for (name, bytes) in hostile {
                try await server.reconnect()
                try await server.write(bytes)
                let responses = try await server.readAllResponses()
                checkEqual(responses.count, 1, "\(name): exactly one response, got \(responses.map(\.status))")
                guard let response = responses.first else { continue }
                check((400...499).contains(response.status) || response.status == 413,
                      "\(name): refused with a client-error status, got \(response.status)")
                checkEqual(response.header("connection"), "close", "\(name): the connection is closed")
                checkEqual(response.header("content-length").flatMap { Int($0) }, response.body.count,
                           "\(name): Content-Length matches the body, so nothing can be appended to it")
            }

            // Raw bytes this time: no Swift string can hold an invalid UTF-8
            // sequence, and `String(data:encoding:)` returning nil is exactly the
            // path under test.
            try await server.reconnect()
            try await server.write(bytes: Data("GET /api/photos HTTP/1.1\r\nHost: ".utf8)
                + Data([0xC3, 0x28, 0xFF, 0xFE])
                + Data("\r\n\r\nGET /favicon.ico HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
            let invalid = try await server.readAllResponses()
            checkEqual(invalid.map(\.status), [400], "a header block that is not UTF-8 is refused, once")
            check(invalid.first?.bodyString.contains("malformed request headers") == true,
                  "and says why: \(invalid.first?.bodyString ?? "")")
            checkEqual(invalid.first?.header("connection"), "close", "and closes the connection")

            // A request split across packets is buffered, never answered early.
            try await server.reconnect()
            try await server.write("GET /api/pho")
            try await Task.sleep(nanoseconds: 300_000_000)
            checkNil(try await server.readOptionalResponse(afterSeconds: 1),
                     "nothing is answered to a request that has not finished arriving")
            try await server.write("tos?limit=1 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            checkEqual(try await server.readResponse()?.status, 200, "and it completes normally once it has")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "an unparseable Content-Length is refused", knownBug: nil) {
        try await withServer { server in
            try await server.write("""
            POST /api/selection/preview HTTP/1.1\r
            Host: x\r
            Content-Length: banana\r
            \r

            """)
            let response = checkNotNil(try await server.readResponse(), "the response")
            checkEqual(response?.status, 400, "a Content-Length that is not a number must not be read as zero")
            check(response?.bodyString.contains("malformed selection") == true,
                  "the request is dispatched and refused as malformed, not framed: \(response?.bodyString ?? "")")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a header line with no colon is ignored, not fatal",
        knownBug: nil) {
        try await withServer { server in
            try await server.write("""
            GET /favicon.ico HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            a-line-with-no-colon\r
            Connection: close\r
            \r

            """)
            checkEqual(try await server.readResponse()?.status, 204, "the request still parses")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a header with no space after the colon is read",
        knownBug: nil) {
        try await withServer { server in
            try await server.write("""
            GET /api/photos?limit=abc HTTP/1.1\r
            Host:127.0.0.1:\(server.port)\r
            Connection:close\r
            X-Pad:\r
            \r

            """)
            let response = checkNotNil(try await server.readResponse(), "the response")
            checkEqual(response?.status, 200, "status")
            checkEqual(response?.header("connection"), "close", "`Connection:close` with no space is understood")
            let json = response.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
            checkEqual((json?["items"] as? [Any])?.count, 12,
                       "an unparseable limit fell back to 60, which is more than the 12 rows that exist")
        }
    })

    // MARK: parsing

    Registry.shared.add(suite: suite, TestCase(name: "the path is split before it is decoded", knownBug: nil) {
        try await withServer { server in
            // A Photos `localIdentifier` contains slashes. Percent-encoded it is one
            // segment; unencoded the server joins the remainder back together.
            try await server.write("""
            GET /api/photo/no%2Fsuch%2Fasset HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            Connection: close\r
            \r

            """)
            let escaped = checkNotNil(try await server.readResponse(), "the escaped form")
            checkEqual(escaped?.status, 404, "an escaped identifier reaches the cache lookup as one identifier")
            check(escaped?.bodyString.contains("unknown asset") == true,
                  "and is simply unknown: \(escaped?.bodyString ?? "")")

            try await server.reconnect()
            try await server.write("""
            GET /api/photo/no/such/asset HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            Connection: close\r
            \r

            """)
            let raw = checkNotNil(try await server.readResponse(), "the raw form")
            checkEqual(raw?.status, escaped?.status, "the raw form has the same status")
            // Compared as parsed JSON, not as bytes: `HTTPResponse.error` does not
            // sort its keys (see the byte-stability case below).
            let rawJSON = (try? JSONSerialization.jsonObject(with: raw?.body ?? Data())) as? [String: Any]
            let escapedJSON = (try? JSONSerialization.jsonObject(with: escaped?.body ?? Data())) as? [String: Any]
            checkEqual(rawJSON?["error"] as? String, escapedJSON?["error"] as? String,
                       "an escaped identifier and a raw one are one identifier")
            checkEqual(rawJSON?["status"] as? Int, escapedJSON?["status"] as? Int, "with the same body")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a + in a path stays a +, a + in a query is a space",
        knownBug: nil) {
        // Decoding a path with the form-urlencoded grammar would rewrite `+` to a
        // space and make an identifier containing a plus unreachable.
        try await withServer(extraSeed: [.init(id: "a+b", score: 0.5, date: 1000)]) { server in
            try await server.write("""
            GET /api/photo/a%2Bb HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            Connection: close\r
            \r

            """)
            checkEqual(try await server.readResponse()?.status, 200, "the escaped plus finds the asset")

            try await server.reconnect()
            try await server.write("""
            GET /api/photo/a+b HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            Connection: close\r
            \r

            """)
            let raw = checkNotNil(try await server.readResponse(), "the raw form")
            checkEqual(raw?.status, 200, "a literal + in the path is a plus, not a space")
            checkEqual((try JSONSerialization.jsonObject(with: raw!.body) as? [String: Any])?["photo"]
                .flatMap { ($0 as? [String: Any])?["id"] } as? String, "a+b", "and it is the same asset")

            // The query grammar keeps the form-urlencoded rule.
            try await server.reconnect()
            try await server.write("""
            GET /api/photos?limit=1&sort=score_asc&x=a+b HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            Connection: close\r
            \r

            """)
            checkEqual(try await server.readResponse()?.status, 200, "an unknown query parameter is ignored, + and all")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "the embedded UI is served over HTTP", knownBug: nil) {
        try await withServer { server in
            try await server.write("""
            GET / HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            Connection: close\r
            \r

            """)
            let response = checkNotNil(try await server.readResponse(), "the response")
            checkEqual(response?.status, 200, "status")
            checkEqual(response?.header("content-type"), "text/html; charset=utf-8", "content type")
            checkEqual(response?.header("content-length").flatMap { Int($0) }, response?.body.count,
                       "the whole document is framed, not chunked or truncated")
            check(response?.bodyString.contains("<html") == true, "an HTML document")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "Server-Sent Events are chunked and start with a status frame",
        knownBug: nil) {
        try await withServer { server in
            try await server.write("""
            GET /api/events HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            Accept: text/event-stream\r
            \r

            """)
            let header = checkNotNil(try await server.readHeader(), "the stream header")
            checkEqual(header?.status, 200, "status line")
            checkEqual(header?.header("transfer-encoding"), "chunked", "the stream is chunked")
            checkEqual(header?.header("cache-control"), "no-cache, no-transform", "and marked no-cache")
            check((header?.header("content-type") ?? "").hasPrefix("text/event-stream"), "content type")

            let chunk = checkNotNil(try await server.readChunk(), "the first frame")
            let text = String(decoding: chunk ?? Data(), as: UTF8.self)
            check(text.hasPrefix("event: status\n"), "the first frame is a status event, got \(text.debugDescription)")
            check(text.contains("\"phase\""), "carrying the status document")
            check(text.hasSuffix("\n\n"), "and terminated by a blank line")
            checkNil(try await server.readOptionalChunk(), "and nothing else arrives without a new publish")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "the listener is loopback-only", knownBug: nil) {
        try await withServer { server in
            check(try await server.canConnect(port: server.port), "127.0.0.1 is reachable")
            let others = Loopback.nonLoopbackIPv4Addresses()
            check(!others.isEmpty, "this host has a non-loopback IPv4 address to test against: \(others)")
            for address in others {
                let reachable = try await server.canConnect(port: server.port, address: address)
                check(!reachable, "\(address):\(server.port) must not accept a connection")
            }
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "each server instance has its own port and cache",
        knownBug: nil) {
        try await withServer { server in
            try await withServer(extraSeed: [.init(id: "only-here", score: 0.5, date: 2000)]) { other in
                check(other.port != server.port, "the harness picks a free port for each")
                try await server.write("GET /api/photos?limit=100 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                let mine = checkNotNil(try await server.readResponse(), "the first server's response")
                let json = mine.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
                checkEqual(json?["total"] as? Int, 12, "the first server sees its own cache")
                try await other.write("GET /api/photos?limit=100 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                let theirs = checkNotNil(try await other.readResponse(), "the second server's response")
                let otherJSON = theirs.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
                checkEqual(otherJSON?["total"] as? Int, 13, "and the second sees its own")
            }
        }
    })

    // MARK: slow cases, on the production timers

    Registry.shared.add(suite: suite, TestCase(name: "an idle connection is closed by the idle deadline",
        knownBug: nil) {
        guard slowTestsEnabled else {
            throw SkipTest(reason: "waits on the production 20 s idle deadline; set PHOTOCLEANER_SLOW_TESTS=1")
        }
        try await withServer { server in
            try await server.write("GET /api/status HTTP/1.1\r\nHost: x\r\n\r\n")
            _ = try await server.readResponse()
            checkNil(try await server.readOptionalResponse(afterSeconds: 26),
                     "the idle connection is reclaimed without sending anything")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a half-sent request is closed by the idle deadline",
        knownBug: nil) {
        guard slowTestsEnabled else {
            throw SkipTest(reason: "waits on the production 20 s idle deadline; set PHOTOCLEANER_SLOW_TESTS=1")
        }
        try await withServer { server in
            // A request line with no terminating blank line is unparseable and
            // unanswerable, so the idle timer is the only thing that can reclaim it.
            try await server.write("GET /api/photos HTTP/1.1\r\nHost: x\r\n")
            checkNil(try await server.readOptionalResponse(afterSeconds: 26),
                     "nothing is answered to a request that never arrived")
        }
    })
}

// MARK: - Server harness

/// Starts the real `HTTPServer` on a free loopback port with a real `Router`, and
/// drives it with a blocking socket client on a dedicated queue.
func withServer(extraSeed: [Fixture.Seed] = [],
                _ body: @Sendable (TestServer) async throws -> Void) async throws {
    let server = try await TestServer.start(extraSeed: extraSeed)
    defer { server.stop() }
    try await body(server)
}

final class TestServer: @unchecked Sendable {
    let port: UInt16
    private let http: HTTPServer
    private let client: BlockingSocket

    private init(port: UInt16, http: HTTPServer, client: BlockingSocket) {
        self.port = port
        self.http = http
        self.client = client
    }

    static func start(extraSeed: [Fixture.Seed] = []) async throws -> TestServer {
        let fixture = try await Fixture.make("http")
        try await fixture.seed((0..<12).map {
            .init(id: "h-\(String(format: "%02d", $0))", score: Float($0) / 20, date: Double(1000 + $0))
        })
        try await fixture.seed(extraSeed)
        // Pin a free port, then let go of it: `HTTPServer` has no API for asking
        // which port the kernel chose.
        let port = try Loopback.freePort()
        let http = HTTPServer(port: port, router: fixture.router)
        try await http.start()
        let client = try BlockingSocket(port: port)
        return TestServer(port: port, http: http, client: client)
    }

    func stop() {
        client.close()
        http.stop()
    }

    func write(_ text: String) async throws {
        try await off { try self.client.write(Data(text.utf8)) }
    }

    func write(bytes: Data) async throws {
        try await off { try self.client.write(bytes) }
    }

    func reconnect() async throws {
        try await off { try self.client.reconnect(self.port) }
    }

    func canConnect(port: UInt16, address: String = "127.0.0.1") async throws -> Bool {
        try await off { self.client.canConnect(port: port, address: address) }
    }

    func readHeader() async throws -> ParsedResponse? {
        try await off { try self.client.readResponse(allowHeadersOnly: true) }
    }

    func readChunk() async throws -> Data? {
        try await off { try self.client.readChunk() }
    }

    func readOptionalChunk(afterSeconds: TimeInterval = 3) async throws -> Data? {
        try await off { try self.client.readChunk(afterSeconds: afterSeconds) }
    }

    func readResponse(afterSeconds: TimeInterval = 10) async throws -> ParsedResponse? {
        try await off { try self.client.readResponse(afterSeconds: afterSeconds) }
    }

    func readOptionalResponse(afterSeconds: TimeInterval = 3) async throws -> ParsedResponse? {
        try await off { try self.client.readResponse(afterSeconds: afterSeconds) }
    }

    func readAllResponses() async throws -> [ParsedResponse] {
        try await off { try self.client.readAllResponses() }
    }

    /// Every byte the server sends within the window, parsed as nothing at all.
    ///
    /// The only way to assert "no second response was written into this stream" is
    /// to look at the bytes: a response parser stops at the first header block, so
    /// a spliced `413` in the middle of a chunked body is exactly what it cannot
    /// see.
    func readRaw(afterSeconds: TimeInterval) async throws -> Data {
        try await off { try self.client.readRaw(afterSeconds: afterSeconds) }
    }

    /// Runs blocking work on a private queue so the cooperative pool is never parked.
    private func off<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            TestServer.io.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static let io = DispatchQueue(label: "com.alastorid.photocleaner.tests.io", qos: .userInitiated)
}

struct ParsedResponse {
    var status = 0
    var reason = ""
    var headers: [String: String] = [:]
    var body = Data()

    func header(_ name: String) -> String? { headers[name.lowercased()] }
    var bodyString: String { String(decoding: body, as: UTF8.self) }
}

enum Loopback {
    /// Binds a socket to port 0 to learn a free port, then releases it.
    static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CacheError.open("could not create a probe socket") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw CacheError.open("could not bind a probe socket") }
        guard listen(fd, 1) == 0 else { throw CacheError.open("could not listen on the probe socket") }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw CacheError.open("could not read the probe port") }
        return UInt16(bigEndian: assigned.sin_port)
    }

    /// Every non-loopback IPv4 address on this host, so "loopback only" can be
    /// tested rather than merely asserted.
    static func nonLoopbackIPv4Addresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var found: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard entry.pointee.ifa_addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            guard ["en0", "en1", "en2"].contains(String(cString: entry.pointee.ifa_name)) else { continue }
            var address = entry.pointee.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(&address, socklen_t(entry.pointee.ifa_addr.pointee.sa_len), &host,
                             socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if !text.hasPrefix("127.") && !found.contains(text) { found.append(text) }
        }
        return found
    }
}

/// A blocking, single-connection HTTP/1.1 client. Only ever pointed at 127.0.0.1.
final class BlockingSocket: @unchecked Sendable {
    private var fd: Int32 = -1
    private var pending = Data()
    private var headerBytes = Data()
    private(set) var port: UInt16

    init(port: UInt16) throws {
        self.port = port
        fd = try BlockingSocket.connect(port: port)
    }

    func reconnect(_ port: UInt16) throws {
        close()
        self.port = port
        fd = try BlockingSocket.connect(port: port)
    }

    func canConnect(port: UInt16, address: String) -> Bool {
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { Darwin.close(probe) }
        var value = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(probe, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        var sockaddrAddress = sockaddr_in()
        sockaddrAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sockaddrAddress.sin_family = sa_family_t(AF_INET)
        sockaddrAddress.sin_port = in_port_t(port.bigEndian)
        sockaddrAddress.sin_addr.s_addr = inet_addr(address)
        let result = withUnsafePointer(to: &sockaddrAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        pending = Data()
        headerBytes = Data()
    }

    private static func connect(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CacheError.open("could not create a client socket") }
        var value = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port.bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw CacheError.open("could not connect to 127.0.0.1:\(port)")
        }
        return fd
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard var cursor = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let written = Darwin.write(fd, cursor, left)
                guard written > 0 else { throw CacheError.open("the client socket stopped accepting writes") }
                cursor += written
                left -= written
            }
        }
    }

    @discardableResult
    private func fill(deadline: Date) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 32 * 1024)
        let remaining = max(0.05, deadline.timeIntervalSinceNow)
        var value = timeval(tv_sec: Int(remaining.rounded(.down)),
                            tv_usec: Int32(((remaining - floor(remaining)) * 1_000_000).rounded(.down)))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        let count = recv(fd, &chunk, chunk.count, 0)
        guard count > 0 else { return false }
        pending.append(contentsOf: chunk[0..<count])
        return true
    }

    /// Reads until the blank line that ends the headers, or nothing more arrives.
    private func readHeaderBlock(deadline: Date) -> Bool {
        headerBytes = Data()
        let marker = Data("\r\n\r\n".utf8)
        while true {
            if let range = pending.range(of: marker) {
                headerBytes = Data(pending[pending.startIndex..<range.lowerBound])
                pending = Data(pending[range.upperBound...])
                return true
            }
            guard Date() < deadline, fill(deadline: deadline) else { return false }
        }
    }

    private func parseHeader() -> ParsedResponse {
        let text = String(decoding: headerBytes, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        var response = ParsedResponse()
        response.status = statusLine.count > 1 ? Int(statusLine[1]) ?? 0 : 0
        response.reason = statusLine.count > 2 ? String(statusLine[2...].joined(separator: " ")) : ""
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            response.headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return response
    }

    /// Reads one response. `afterSeconds` bounds the wait; `allowHeadersOnly` stops
    /// after the header block, which is what a chunked stream needs.
    func readResponse(afterSeconds: TimeInterval = 10, allowHeadersOnly: Bool = false) throws -> ParsedResponse? {
        let deadline = Date().addingTimeInterval(afterSeconds)
        guard readHeaderBlock(deadline: deadline) else {
            guard pending.isEmpty, headerBytes.isEmpty else {
                // A partial response is a protocol violation, not silence.
                throw CacheError.open("a partial response arrived: \(pending.prefix(64).debugDescription)")
            }
            return nil
        }
        var response = parseHeader()
        if allowHeadersOnly || response.header("transfer-encoding")?.lowercased() == "chunked" { return response }

        let length = Int(response.header("content-length") ?? "") ?? 0
        while pending.count < length {
            guard Date() < deadline, fill(deadline: deadline) else { return response }
        }
        response.body = Data(pending.prefix(length))
        pending = Data(pending.dropFirst(length))
        return response
    }

    func readAllResponses() throws -> [ParsedResponse] {
        var responses: [ParsedResponse] = []
        for _ in 0..<8 {
            guard let response = try readResponse(afterSeconds: 3) else { break }
            responses.append(response)
        }
        return responses
    }

    /// Drains everything that arrives within the window and returns it verbatim,
    /// leaving the buffer empty. Bounded by the window, not by the socket: a
    /// server that has said nothing more is a result, not a hang.
    func readRaw(afterSeconds: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(afterSeconds)
        while Date() < deadline, fill(deadline: deadline) {}
        let data = pending
        pending = Data()
        return data
    }

    /// Reads one HTTP chunk frame, or `nil` if none arrives.
    func readChunk(afterSeconds: TimeInterval = 3) throws -> Data? {
        let deadline = Date().addingTimeInterval(afterSeconds)
        let marker = Data("\r\n".utf8)
        while pending.count < 2 || pending.range(of: marker) == nil {
            guard Date() < deadline, fill(deadline: deadline) else { return nil }
        }
        guard let lineEnd = pending.range(of: marker) else { return nil }
        let sizeField = String(decoding: pending[pending.startIndex..<lineEnd.lowerBound], as: UTF8.self)
        pending = Data(pending[lineEnd.upperBound...])
        let size = Int(sizeField.trimmingCharacters(in: .whitespaces), radix: 16) ?? 0
        if size == 0 { return Data() }
        while pending.count < size + 2 {
            guard Date() < deadline, fill(deadline: deadline) else { return nil }
        }
        let body = Data(pending.prefix(size))
        pending = Data(pending.dropFirst(size + 2))
        return body
    }
}