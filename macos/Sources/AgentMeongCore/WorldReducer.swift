import Foundation

public struct WorldReducer: Sendable {
    public private(set) var state = WorldState()
    private var consumedEventIds: Set<String> = []
    private var consumedEventOrder: [String] = []
    private let deduplicationCapacity: Int
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
        failedInterval: TimeInterval = 30,
        deduplicationCapacity: Int = 4_096
    ) {
        self.staleInterval = staleInterval
        self.uncertainInterval = uncertainInterval
        self.attentionInterval = attentionInterval
        self.completedInterval = completedInterval
        self.failedInterval = failedInterval
        self.deduplicationCapacity = max(1, deduplicationCapacity)
    }

    @discardableResult
    public mutating func apply(_ observation: ActivityObservation) -> WorldState {
        applyWithEffects(observation).state
    }

    @discardableResult
    public mutating func applyWithEffects(_ observation: ActivityObservation) -> WorldUpdate {
        guard consume(observation.eventId) else {
            return WorldUpdate(state: state, effects: [], observationAccepted: false)
        }
        let previous = state.actors[observation.actorId]
        guard shouldApply(observation, after: previous) else {
            return WorldUpdate(state: state, effects: [], observationAccepted: false)
        }
        let nextActor = reduce(previous, observation)
        state.actors[observation.actorId] = nextActor
        let effects = effects(for: observation, actor: nextActor)
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
                scopeId: nil,
                at: observation.occurredAt
            )
        }
        return WorldUpdate(state: state, effects: effects, observationAccepted: true)
    }

    /// Restores only live, non-future actor metadata and immediately applies
    /// the original observation-time TTL. Restoration intentionally emits no
    /// lifecycle effects or completion notifications.
    @discardableResult
    public mutating func restore(_ checkpoint: WorldCheckpoint, at now: Date) -> WorldState {
        state = WorldState()
        consumedEventIds.removeAll(keepingCapacity: true)
        consumedEventOrder.removeAll(keepingCapacity: true)
        guard checkpoint.schemaVersion == WorldCheckpoint.currentSchemaVersion else {
            return state
        }

        for actor in checkpoint.actors {
            guard
                !actor.id.isEmpty,
                !actor.source.isEmpty,
                !actor.sessionId.isEmpty,
                actor.lastObservedAt <= now,
                state.actors[actor.id] == nil
            else { continue }
            switch actor.visualState {
            case .active, .attention, .uncertain:
                state.actors[actor.id] = actor
            case .quiet, .completed, .cancelled, .failed:
                continue
            }
        }
        return expire(at: now)
    }

    private mutating func consume(_ eventId: String) -> Bool {
        guard consumedEventIds.insert(eventId).inserted else { return false }
        consumedEventOrder.append(eventId)
        if consumedEventOrder.count > deduplicationCapacity {
            let overflow = consumedEventOrder.count - deduplicationCapacity
            for expiredId in consumedEventOrder.prefix(overflow) {
                consumedEventIds.remove(expiredId)
            }
            consumedEventOrder.removeFirst(overflow)
        }
        return true
    }

    @discardableResult
    public mutating func expire(at now: Date) -> WorldState {
        let actors = state.actors
        for (id, actor) in actors {
            let age = now.timeIntervalSince(actor.lastObservedAt)
            if (actor.visualState == .completed || actor.visualState == .cancelled),
                age >= completedInterval
            {
                state.actors.removeValue(forKey: id)
                continue
            }
            if actor.visualState == .failed, age >= failedInterval {
                state.actors.removeValue(forKey: id)
                continue
            }
            var next = actor
            if actor.visualState == .active {
                if age >= staleInterval + uncertainInterval {
                    state.actors.removeValue(forKey: id)
                    continue
                }
                if age >= staleInterval {
                    next.visualState = .uncertain
                    next.toolCategory = nil
                    next.lastObservedAt = actor.lastObservedAt.addingTimeInterval(staleInterval)
                }
            } else if actor.visualState == .attention {
                if age >= attentionInterval + uncertainInterval {
                    state.actors.removeValue(forKey: id)
                    continue
                }
                if age >= attentionInterval {
                    next.visualState = .uncertain
                    next.toolCategory = nil
                    next.lastObservedAt = actor.lastObservedAt.addingTimeInterval(attentionInterval)
                }
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
        case .completed, .cancelled: completedInterval
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
        var descendants: Set<String> = [parentId]
        var foundNewDescendant = true
        while foundNewDescendant {
            foundNewDescendant = false
            for actor in actors.values {
                guard
                    actor.sessionId == sessionId,
                    scopeId == nil || actor.scopeId == nil || actor.scopeId == scopeId,
                    let directParent = actor.parentActorId,
                    descendants.contains(directParent),
                    descendants.insert(actor.id).inserted
                else { continue }
                foundNewDescendant = true
            }
        }

        for id in descendants where id != parentId {
            guard let actor = actors[id] else { continue }
            guard actor.visualState == .active || actor.visualState == .attention else { continue }
            var settling = actor
            settling.visualState = .uncertain
            settling.toolCategory = nil
            settling.lastObservedAt = date
            state.actors[id] = settling
        }
    }

    private func effects(
        for observation: ActivityObservation,
        actor: ActorState
    ) -> [WorldEffect] {
        if observation.kind == .agentStarted, let parentId = actor.parentActorId {
            return [.childStarted(actorId: actor.id, parentActorId: parentId)]
        }
        let isTerminal = observation.kind == .agentFinished || observation.kind == .turnStopping
        guard isTerminal else { return [] }
        guard actor.visualState == .completed else { return [] }
        if let parentId = actor.parentActorId {
            return [.childCompleted(actorId: actor.id, parentActorId: parentId)]
        }
        return [.topLevelCompleted]
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
    if isTerminal {
        switch observation.outcome {
        case .failure: return .failed
        case .cancelled: return .cancelled
        case .success, nil: break
        }
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
        case .attention, .completed, .cancelled, .failed:
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
