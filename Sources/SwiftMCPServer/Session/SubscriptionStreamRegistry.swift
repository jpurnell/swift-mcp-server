import Foundation

/// The open `subscriptions/listen` streams, and the notifications delivered on them.
///
/// A subscription stream is not a session. It has no identity beyond itself, outlives no
/// request but its own, and is addressed by the subscription id the server minted when it
/// opened — which is why this is a separate registry from the session managers rather than
/// another field on one of them.
public actor SubscriptionStreamRegistry {
    /// An open stream and the notification kinds it asked for.
    private struct Subscription {
        let stream: SSESession
        /// The keys from the request's `notifications` object that the server agreed to honour.
        let honoured: Set<String>
    }

    private var streams: [String: Subscription] = [:]

    /// The `notifications` key each change notification answers.
    ///
    /// A subscription is expressed in terms of these keys, and delivery is expressed in terms of
    /// method names; without the mapping, filtering would have to be re-derived at each call
    /// site and one of them would get it wrong.
    private static let subscriptionKey: [String: String] = [
        "notifications/tools/list_changed": "toolsListChanged",
        "notifications/prompts/list_changed": "promptsListChanged",
        "notifications/resources/list_changed": "resourcesListChanged",
        "notifications/resources/updated": "resourcesUpdated",
    ]

    /// Creates an empty registry.
    public init() {}

    /// Records an open stream.
    ///
    /// - Parameters:
    ///   - stream: The SSE stream to deliver on.
    ///   - id: The subscription identifier the server minted.
    ///   - honoured: The notification keys the server acknowledged. Delivery is restricted to
    ///     these: the acknowledgement told the client what it would receive, and sending more
    ///     makes that a lie — a client filters because it is not prepared to handle the rest.
    public func register(_ stream: SSESession, id: String, honouring honoured: Set<String>) {
        streams[id] = Subscription(stream: stream, honoured: honoured)
    }

    /// Forgets a stream.
    ///
    /// - Parameter id: The subscription identifier.
    public func remove(id: String) {
        streams.removeValue(forKey: id)
    }

    /// The number of open streams.
    public var count: Int { streams.count }

    /// Delivers a change notification to every open stream.
    ///
    /// Each delivery carries `io.modelcontextprotocol/subscriptionId` in `_meta`, which the
    /// specification requires: a client may hold several subscriptions, and without the tag it
    /// cannot tell which one a notification answers.
    ///
    /// Only change notifications belong here. Request-scoped notifications — progress and log
    /// messages — flow on the response stream of the request they relate to, and sending them
    /// here would attribute them to a subscription that did not cause them.
    ///
    /// - Parameters:
    ///   - method: The notification method, such as `notifications/tools/list_changed`.
    ///   - params: Any parameters, which will be merged with the subscription metadata.
    public func broadcast(method: String, params: [String: Any] = [:]) async {
        let key = Self.subscriptionKey[method]
        for (id, subscription) in streams {
            // A notification nobody subscribed to is not delivered. An unrecognised method is
            // delivered to every stream rather than to none: a kind this registry has not been
            // taught about is more likely new than unwanted, and silently dropping it would be
            // indistinguishable from the server never sending it.
            if let key, !subscription.honoured.contains(key) { continue }
            var merged = params
            var meta = (params["_meta"] as? [String: Any]) ?? [:]
            meta["io.modelcontextprotocol/subscriptionId"] = id
            merged["_meta"] = meta

            let notification: [String: Any] = [
                "jsonrpc": "2.0",
                "method": method,
                "params": merged,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: notification), // silent: a dictionary of literals cannot fail to serialise
                let text = String(data: data, encoding: .utf8)
            else { continue }
            await subscription.stream.sendEvent(data: text)
        }
    }

    /// Sends a keep-alive comment on every open stream.
    ///
    /// A quiet subscription stream is otherwise indistinguishable from a dead one to an
    /// intermediary, which will close it.
    public func sendHeartbeats() async {
        for subscription in streams.values {
            await subscription.stream.sendHeartbeat()
        }
    }
}
