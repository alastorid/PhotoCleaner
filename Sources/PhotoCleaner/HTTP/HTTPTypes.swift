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
        // Emitted by `/api/photo/{id}/video` for every satisfiable `Range`. Missing
        // this would put `HTTP/1.1 206 Status 206` on the wire, which is legal (the
        // phrase is advisory) but is exactly the kind of thing that makes a proxy log
        // or a packet capture look like a server in distress.
        case 206: return "Partial Content"
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
        // 416 exists because of `GET /api/photo/{id}/video`: without it the code
        // would have fallen through to `"Status 416"`, which is the honest phrase
        // for an unrecognised code and a useless one for a client whose seek landed
        // past the end of a clip. RFC 9110 §15.5.17.
        case 416: return "Range Not Satisfiable"
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
    /// A body that lives on disk and is streamed rather than held in memory.
    ///
    /// The third kind of response, and it exists for one route: a video clip can be
    /// gigabytes, and `HTTPResponse.body` is `Data` — so a video served the way every
    /// other route is served would have to be read into memory in full before the
    /// first byte went out. `HTTPConnection.send` handles this case separately, and
    /// the separate handling is load-bearing: it writes the headers it was given and
    /// then feeds the file to `connection.send` in chunks, chained off each write's
    /// completion.
    case file(HTTPFile)
}

/// A response body that is a byte range of a file on local disk.
struct HTTPFile: Sendable {
    /// `200` for a whole file, `206` for a range. Carried rather than derived so
    /// the status line and the `Content-Range` header cannot disagree about which
    /// of the two this is.
    var status: Int
    /// Headers to send verbatim: `Content-Type`, `Content-Range`, `Accept-Ranges`,
    /// `Cache-Control`.
    ///
    /// **`Content-Length` is not one of these, and a value here is overwritten.**
    /// `HTTPConnection.headerBytes` sets it from `length`, because the header is a
    /// promise about framing and only the side that writes the bytes can be right
    /// about it. Letting a caller set it would be a way to announce a length the
    /// connection is not going to honour — and the failure mode of that is a client
    /// that waits out a body which never comes, with no error to show for it.
    var headers: [String: String]
    let url: URL
    /// First byte of the file to send.
    let start: Int64
    /// How many bytes to send from `start`. Not the file's size: for a `206` it is
    /// `b - a + 1`, and getting that wrong desynchronises the client's parser
    /// rather than producing a merely wrong picture.
    let length: Int64
}

/// One `Range` header, resolved against a known file size.
///
/// A standalone value rather than logic inside `HTTPConnection`, because it is a
/// pure function of two inputs and the table it implements is the part of byte-range
/// support a test can actually assert. The server-side consequences — a `200` for a
/// range it declines to honour, a `416` for one it cannot — are decided here so
/// that the connection layer only has to write down what this says.
enum HTTPRange: Equatable, Sendable {
    /// `200`, the whole file.
    case whole(length: Int64)
    /// `206`, these bytes of it.
    case partial(start: Int64, length: Int64)
    /// `416`, with `Content-Range: bytes */size`.
    case unsatisfiable

    /// Resolves a request's `Range` header against `fileSize`.
    ///
    /// ## What is honoured and what is ignored
    ///
    /// Single ranges only. A multi-range request is *ignored* and served as a `200`,
    /// not refused: RFC 9110 §14.2 makes `multipart/byteranges` optional for a
    /// server, and answering it means a second framing mode on a connection whose
    /// framing this server already gets right for everything else. Serving the whole
    /// file is a valid response to any range request, so ignoring it is correct
    /// rather than a compromise.
    ///
    /// An unparseable header is likewise ignored rather than refused. A `500` for a
    /// header this server did not understand would be absurd, and so would guessing
    /// at a byte range from text that is not one — a client asking for `bytes=abc`
    /// and being given 3 bytes of clip at offset 0 would have no way to tell.
    ///
    /// Both ignorable cases therefore fall through to `.whole`, which is exactly the
    /// same path a request with no `Range` at all takes.
    static func resolve(header: String?, fileSize: Int64) -> HTTPRange {
        guard let header, !header.isEmpty else { return .whole(length: fileSize) }
        // The unit is case-insensitive (RFC 9110 §14.1); `bytes` is the only unit
        // this server understands, and anything else is ignored like a malformed one.
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes=") else { return .whole(length: fileSize) }
        let spec = String(value.dropFirst("bytes=".count)).trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty, !spec.contains(",") else { return .whole(length: fileSize) }
        // Exactly one `-`. `split` with `omittingEmptySubsequences: false` keeps the
        // empty halves that make `bytes=-500` and `bytes=500-` expressible; more than
        // two pieces (`bytes=1-2-3`) is not a range at all.
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .whole(length: fileSize) }

        let first = parts[0]
        let last = parts[1]
        if first.isEmpty {
            // `bytes=-<suffix>`: the final N bytes.
            //
            // `suffix-length` is `1*DIGIT`, so anything that is not a run of digits is
            // not a range at all — and is therefore *ignored* like every other
            // unparseable header here, served as the whole file. It is specifically
            // **not** refused: `bytes=-abc` used to answer 416 while the mirror-image
            // `bytes=abc-` answered 200, which is asymmetric with this function's own
            // stated policy and tells a client that a seek is impossible when in fact
            // the server simply did not understand the header. A client cannot act on
            // that distinction, and it cannot retry its way out of it either.
            guard let suffix = Int64(last) else { return .whole(length: fileSize) }
            // A suffix that parses but is zero *is* refused: RFC 9110 §14.1.2 makes
            // it unsatisfiable, because it names an empty range at the very end of
            // the file, which no client means.
            guard suffix > 0 else { return .unsatisfiable }
            let start = max(0, fileSize - suffix)
            return .partial(start: start, length: fileSize - start)
        }
        guard let start = Int64(first) else { return .whole(length: fileSize) }
        // `start >= fileSize` is past the end. So is an inverted range, and answering
        // either with a `206` would hand the client bytes from somewhere it did not
        // ask for — a decoder fed the wrong segment of a clip fails in a way that
        // looks like a corrupt file rather than a bad request.
        guard start < fileSize else { return .unsatisfiable }
        if last.isEmpty {
            // `bytes=<start>-`: to the end of the file.
            return .partial(start: start, length: fileSize - start)
        }
        guard let end = Int64(last) else { return .whole(length: fileSize) }
        guard end >= start else { return .unsatisfiable }
        // A last-byte-pos past the end is *clamped*, not refused: RFC 9110 §14.1.2
        // defines the effective end as the smaller of the two. Refusing it would
        // break every client that asks for more than it knows exists, which is what
        // a media element does when it seeks to a duration it estimated a moment
        // early.
        let effectiveEnd = min(end, fileSize - 1)
        return .partial(start: start, length: effectiveEnd - start + 1)
    }

    /// The `Content-Range` value for this outcome, or nil when there is none to send.
    ///
    /// `416` carries `bytes */size` and no `Content-Range` on the partial form, which
    /// is how a client learns the real length of a resource it asked to seek past —
    /// the one case where the error response is more informative than the success
    /// would have been.
    func contentRangeHeader(fileSize: Int64) -> String? {
        switch self {
        case .whole: return nil
        case .partial(let start, let length):
            guard length > 0 else { return nil }
            return "bytes \(start)-\(start + length - 1)/\(fileSize)"
        case .unsatisfiable: return "bytes */\(fileSize)"
        }
    }
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
}
