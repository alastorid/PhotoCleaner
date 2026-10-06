import Foundation

struct HTTPRequest: Sendable {
    let method: String
    let rawPath: String
    /// Path split on `/`, then each component percent-decoded. Splitting before
    /// decoding is what lets a Photos `localIdentifier` (which itself contains
    /// slashes) travel as a single `%2F`-escaped segment.
    let segments: [String]
    let query: [String: String]
    /// Header names lower-cased.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    func queryValue(_ name: String) -> String? { query[name] }

    func queryInt(_ name: String, default fallback: Int? = nil, range: ClosedRange<Int>? = nil) -> Int? {
        guard let raw = query[name], let value = Int(raw) else { return fallback }
        if let range { return min(max(value, range.lowerBound), range.upperBound) }
        return value
    }

    func queryFloat(_ name: String) -> Float? {
        guard let raw = query[name] else { return nil }
        return Float(raw)
    }
}

enum HTTPStatus {
    /// The reason phrase for a status code.
    ///
    /// This is a *reason phrase*, not a routing decision, so it is filled in for
    /// every code the server can emit rather than for the ones someone expected.
    /// A code with no entry used to fall through to `"OK"`, which put
    /// `HTTP/1.1 409 OK` on the wire for a stale `confirmToken` — a phrase that
    /// contradicts the code, and worse than no phrase at all for anyone reading
    /// a log or a proxy trace. Every status literal in `HTTPServer` and `Router`
    /// has an entry here.
    ///
    /// The unknown-code default is deliberately *not* `"OK"`: an unrecognised
    /// code says nothing about success, so the honest phrase is an
    /// acknowledgement that the code is unrecognised rather than a claim about
    /// it. (HTTP/1.1 requires the phrase to be present, and clients are told to
    /// ignore it.)
    static func text(_ code: Int) -> String {
        switch code {
        // 2xx
        case 200: return "OK"
        case 204: return "No Content"
        // 3xx — not emitted today (nothing redirects), listed so the table is
        // not mistaken for a routing table.
        case 301: return "Moved Permanently"
        case 304: return "Not Modified"
        // 4xx
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 414: return "URI Too Long"
        case 415: return "Unsupported Media Type"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        // 5xx
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Status \(code)"
        }
    }
}

struct HTTPResponse: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()

    /// Every JSON route is a live view of the library — the counters in
    /// `/api/status`, the rows in a page of photos — so none of it may be cached,
    /// by this app or by anything else that asks.
    ///
    /// `no-store` rather than `no-cache`, because `no-cache` still permits the
    /// response to be *written* and only obliges a revalidation: the body would
    /// land in a client's disk cache and could be served from it. `no-store` is
    /// the header that keeps it off disk, which is what `smoke-test.sh` holds the
    /// app to and what the client-side `cache: 'no-store'` fetch option was
    /// working around. Bytes routes carry the same header, per `maxAge`.
    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            var response = HTTPResponse(status: status)
            response.headers["Content-Type"] = "application/json; charset=utf-8"
            response.headers["Cache-Control"] = "no-store"
            response.body = try encoder.encode(value)
            return response
        } catch {
            return .error("could not encode response: \(error)", status: 500)
        }
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        struct Body: Encodable { let error: String; let status: Int }
        let encoder = JSONEncoder()
        var response = HTTPResponse(status: status)
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        response.headers["Cache-Control"] = "no-store"
        response.body = (try? encoder.encode(Body(error: message, status: status))) ?? Data()
        return response
    }

    static func text(_ message: String, status: Int = 200) -> HTTPResponse {
        var response = HTTPResponse(status: status)
        response.headers["Content-Type"] = "text/plain; charset=utf-8"
        response.body = Data(message.utf8)
        return response
    }

    static func bytes(_ data: Data, contentType: String, maxAge: Int = 0, status: Int = 200) -> HTTPResponse {
        var response = HTTPResponse(status: status)
        response.headers["Content-Type"] = contentType
        response.headers["Cache-Control"] = maxAge > 0 ? "private, max-age=\(maxAge)" : "no-store"
        response.body = data
        return response
    }
}

/// A long-lived response (Server-Sent Events). Written with chunked transfer
/// encoding so the browser sees an event stream rather than a stalled document.
struct HTTPStream: Sendable {
    var headers: [String: String]
    var events: AsyncStream<Data>
    var onClose: @Sendable () -> Void
}

enum RouteResult: Sendable {
    case response(HTTPResponse)
    case stream(HTTPStream)
}

extension String {
    /// Percent-decodes one **path** component.
    ///
    /// `+` is a literal plus here, and that is the whole difference from
    /// `percentDecodedQueryValue`: `+` only means "space" in the
    /// `application/x-www-form-urlencoded` body/query encoding that HTML forms
    /// and `URLSearchParams` speak. In a URI *path* `+` is a legal sub-delim
    /// carrying its own meaning (RFC 3986 §3.3), so rewriting it to a space
    /// corrupts any identifier that contains one. Photos
    /// `localIdentifier`s are opaque strings handed to us by the framework, and
    /// nothing promises they stay alphanumeric — hence two functions with
    /// names that say which grammar they decode, rather than one that silently
    /// applies the wrong one.
    ///
    /// Splitting the path on `/` *before* decoding (see `HTTPServer.makeRequest`)
    /// is what lets an identifier that itself contains slashes travel as a
    /// single `%2F`-escaped segment; decoding cannot introduce a separator.
    var percentDecodedPathSegment: String {
        removingPercentEncoding ?? self
    }

    /// Percent-decodes one query-string name or value, including the
    /// `+`-means-space rule of `application/x-www-form-urlencoded`.
    ///
    /// Byte-identical to the previous single `percentDecoded` property for
    /// query input; see `percentDecodedPathSegment` for why the path cannot use
    /// this one. Note that a `%2B`-escaped plus still decodes to a literal plus
    /// here, which is what a correct client sends either way.
    var percentDecodedQueryValue: String {
        let value = replacingOccurrences(of: "+", with: " ")
        return value.removingPercentEncoding ?? value
    }

    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
