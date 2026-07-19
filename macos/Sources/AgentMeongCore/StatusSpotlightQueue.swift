public struct StatusSpotlightQueue: Equatable, Sendable {
    public let capacity: Int
    public private(set) var pending: [AgentStateSignal] = []

    public init(capacity: Int = 6) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { pending.count }

    /// Keeps at most one pending state per actor. A newer state moves to the
    /// back so another actor already waiting is not starved by rapid updates.
    public mutating func enqueue(_ signal: AgentStateSignal) {
        pending.removeAll { $0.actorId == signal.actorId }
        pending.append(signal)
        if pending.count > capacity {
            pending.removeFirst(pending.count - capacity)
        }
    }

    public mutating func enqueue(contentsOf signals: [AgentStateSignal]) {
        signals.forEach { enqueue($0) }
    }

    public mutating func remove(actorId: String) {
        pending.removeAll { $0.actorId == actorId }
    }

    public mutating func retain(actorIds: Set<String>) {
        pending.removeAll { !actorIds.contains($0.actorId) }
    }

    public mutating func popFirst() -> AgentStateSignal? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    public mutating func removeAll() {
        pending.removeAll(keepingCapacity: true)
    }
}
