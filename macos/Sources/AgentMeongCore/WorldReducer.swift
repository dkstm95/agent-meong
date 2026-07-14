import Foundation

public struct WorldReducer: Sendable {
    public private(set) var state = WorldState()
    private var consumedEventIds: Set<String> = []
    private let staleInterval: TimeInterval
    private let uncertainInterval: TimeInterval
    private let attentionInterval: TimeInterval
    private let completedInterval: TimeInterval
    private let failedInterval: TimeInterval

    public init(
        staleInterval: TimeInterval = 90,
        uncertainInterval: TimeInterval = 12,
        attentionInterval: TimeInterval = 600,
        completedInterval: TimeInterval = 8,
        failedInterval: TimeInterval = 30
    ) {
        self.staleInterval = staleInterval
        self.uncertainInterval = uncertainInterval
        self.attentionInterval = attentionInterval
        self.completedInterval = completedInterval
        self.failedInterval = failedInterval
    }

    @discardableResult
    public mutating func apply(_ observation: ActivityObservation) -> WorldState {
        guard consumedEventIds.insert(observation.eventId).inserted else {
            return state
        }
        let previous = state.actors[observation.actorId]
        guard shouldApply(observation, after: previous) else { return state }
        state.actors[observation.actorId] = reduce(previous, observation)
        if startsNewScope(observation, after: previous) {
            settleSessionChildren(
                of: observation.actorId,
                sessionId: observation.sessionId,
                scopeId: previous?.scopeId,
                at: observation.occurredAt
            )
        }
        if observation.kind == .turnStopping, observation.parentActorId == nil {
            settleSessionChildren(
                of: observation.actorId,
                sessionId: observation.sessionId,
                scopeId: observation.scopeId,
                at: observation.occurredAt
            )
        }
        return state
    }

    @discardableResult
    public mutating func expire(at now: Date) -> WorldState {
        let actors = state.actors
        for (id, actor) in actors {
            let age = now.timeIntervalSince(actor.lastObservedAt)
            if actor.visualState == .completed, age >= completedInterval {
                state.actors.removeValue(forKey: id)
                continue
            }
            if actor.visualState == .failed, age >= failedInterval {
                state.actors.removeValue(forKey: id)
                continue
            }
            var next = actor
            if actor.visualState == .active, age >= staleInterval {
                next.visualState = .uncertain
                next.toolCategory = nil
                next.lastObservedAt = now
            } else if actor.visualState == .attention, age >= attentionInterval {
                next.visualState = .uncertain
                next.toolCategory = nil
                next.lastObservedAt = now
            } else if actor.visualState == .uncertain, age >= uncertainInterval {
                state.actors.removeValue(forKey: id)
                continue
            }
            if actor.visualState == .quiet, age >= staleInterval {
                state.actors.removeValue(forKey: id)
            } else {
                state.actors[id] = next
            }
        }
        return state
    }

    public func nextExpiryDate() -> Date? {
        state.actors.values.compactMap { actor in
            actor.lastObservedAt.addingTimeInterval(expiryInterval(for: actor.visualState))
        }.min()
    }

    private func expiryInterval(for visualState: VisualState) -> TimeInterval {
        switch visualState {
        case .quiet, .active: staleInterval
        case .attention: attentionInterval
        case .uncertain: uncertainInterval
        case .completed: completedInterval
        case .failed: failedInterval
        }
    }

    private func reduce(
        _ previous: ActorState?,
        _ observation: ActivityObservation
    ) -> ActorState {
        ActorState(
            id: observation.actorId,
            source: observation.source,
            sessionId: observation.sessionId,
            parentActorId: observation.parentActorId ?? previous?.parentActorId,
            scopeId: observation.scopeId ?? previous?.scopeId,
            seed: previous?.seed ?? stableSeed(observation.actorId),
            visualState: visualState(for: observation, previous: previous),
            toolCategory: observation.toolCategory ?? previous?.toolCategory,
            lastObservedAt: observation.occurredAt
        )
    }

    private mutating func settleSessionChildren(
        of parentId: String,
        sessionId: String,
        scopeId: String?,
        at date: Date
    ) {
        let actors = state.actors
        for (id, actor) in actors where belongsToScope(actor, parentId, sessionId, scopeId) {
            guard actor.visualState == .active else { continue }
            var settling = actor
            settling.visualState = .uncertain
            settling.toolCategory = nil
            settling.lastObservedAt = date
            state.actors[id] = settling
        }
    }

    private func belongsToScope(
        _ actor: ActorState,
        _ parentId: String,
        _ sessionId: String,
        _ scopeId: String?
    ) -> Bool {
        actor.sessionId == sessionId
            && actor.id != parentId
            && (scopeId == nil || actor.scopeId == scopeId)
    }

    private func startsNewScope(
        _ observation: ActivityObservation,
        after previous: ActorState?
    ) -> Bool {
        observation.kind == .turnStarted
            && observation.parentActorId == nil
            && previous?.scopeId != nil
            && previous?.scopeId != observation.scopeId
    }

    private func shouldApply(
        _ observation: ActivityObservation,
        after previous: ActorState?
    ) -> Bool {
        guard let previous else { return true }
        if observation.occurredAt < previous.lastObservedAt { return false }
        let isTerminal = observation.kind == .agentFinished || observation.kind == .turnStopping
        if isTerminal, let oldScope = previous.scopeId, let newScope = observation.scopeId {
            return oldScope == newScope
        }
        return true
    }

}

private func visualState(
    for observation: ActivityObservation,
    previous: ActorState?
) -> VisualState {
    let isTerminal = observation.kind == .agentFinished || observation.kind == .turnStopping
    if isTerminal, observation.outcome == .failure {
        return .failed
    }

    switch observation.kind {
    case .sessionOpened:
        return .quiet
    case .turnStarted, .toolStarted, .toolFinished, .agentStarted:
        return .active
    case .approvalWaiting:
        return .attention
    case .agentFinished, .turnStopping:
        return .completed
    case .heartbeat:
        switch previous?.visualState {
        case .attention, .completed, .failed:
            return previous?.visualState ?? .active
        case .quiet, .active, .uncertain, nil:
            return .active
        }
    }
}

public func stableSeed(_ value: String) -> UInt64 {
    value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
        (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
}
