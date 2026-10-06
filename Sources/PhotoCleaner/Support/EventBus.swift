import Foundation
import os

/// Fan-out for Server-Sent Events.
///
/// One `AsyncStream` per connected browser. Progress events are coalesced to the
/// newest value (`.bufferingNewest(1)`) so a slow client can never build an
/// unbounded queue of stale progress, and a stalled client can never apply
/// back-pressure to the analysis engine.
final class EventBus: Sendable {
    struct Subscription: Sendable {
        let id: UUID
        let stream: AsyncStream<Data>
    }

    private struct State {
        var subscribers: [UUID: AsyncStream<Data>.Continuation] = [:]
        /// The retained snapshot handed to a browser the instant it subscribes.
        /// Only ever a *state* frame — see `broadcast`.
        var latest: Data?
        var closed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func subscribe() -> Subscription {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let outcome = state.withLock { current -> (closed: Bool, latest: Data?) in
            if current.closed { return (true, nil) }
            current.subscribers[id] = continuation
            return (false, current.latest)
        }
        if outcome.closed {
            // Never hand back a stream nobody will ever finish: the consumer
            // would wait on `for await` until its task was cancelled.
            continuation.finish()
        } else if let latest = outcome.latest {
            continuation.yield(latest)
        }
        return Subscription(id: id, stream: stream)
    }

    func unsubscribe(_ id: UUID) {
        state.withLock { current in
            current.subscribers[id]?.finish()
            current.subscribers.removeValue(forKey: id)
        }
    }

    /// Publishes a *state* frame: retained for new subscribers and fanned out.
    func publish(_ data: Data) {
        state.withLock { current in
            guard !current.closed else { return }
            current.latest = data
            for continuation in current.subscribers.values {
                continuation.yield(data)
            }
        }
    }

    /// Fans a frame out to live subscribers **without** touching the retained
    /// snapshot.
    ///
    /// This is the transport channel, not the state channel. An SSE heartbeat is
    /// a `:` comment frame: it exists to keep proxies and the browser from
    /// timing out an idle connection. If it went through `publish` it would
    /// replace the retained snapshot, and a browser subscribing in the window
    /// between `Engine.publishStatus(force:)` and `Router.events()`'s
    /// `bus.subscribe()` would receive `": ping"` instead of a `status` snapshot
    /// — the one guarantee the immediate-publish path exists to provide.
    func broadcast(_ data: Data) {
        state.withLock { current in
            guard !current.closed else { return }
            for continuation in current.subscribers.values {
                continuation.yield(data)
            }
        }
    }

    func close() {
        state.withLock { current in
            current.closed = true
            for continuation in current.subscribers.values {
                continuation.finish()
            }
            current.subscribers.removeAll()
        }
    }
}

/// Encodes a named SSE event as one `text/event-stream` frame.
enum SSE {
    static func frame(event: String, json: Data) -> Data {
        var out = Data()
        out.append(contentsOf: "event: \(event)\n".utf8)
        // JSON never contains a raw newline, so a single `data:` line is safe.
        out.append(contentsOf: "data: ".utf8)
        out.append(json)
        out.append(contentsOf: "\n\n".utf8)
        return out
    }

    static let heartbeat = Data(": ping\n\n".utf8)
}
