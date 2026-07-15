import Foundation

public enum VisualState: String, Codable, Sendable {
    case quiet
    case active
    case attention
    case uncertain
    case completed
    case cancelled
    case failed
}

public struct ActorState: Equatable, Sendable {
    public let id: String
    public let source: String
    public let sessionId: String
    public let parentActorId: String?
    public var scopeId: String?
    public let seed: UInt64
    public var visualState: VisualState
    public var toolCategory: ToolCategory?
    public var lastObservedAt: Date
}

public struct WorldState: Equatable, Sendable {
    public internal(set) var actors: [String: ActorState] = [:]

    public init() {}

    public var orderedActors: [ActorState] {
        actors.values.sorted { $0.id < $1.id }
    }

    public var aggregateState: VisualState {
        if actors.values.contains(where: { $0.visualState == .failed }) {
            return .failed
        }
        if actors.values.contains(where: { $0.visualState == .attention }) {
            return .attention
        }
        if actors.values.contains(where: { $0.visualState == .uncertain }) {
            return .uncertain
        }
        if actors.values.contains(where: { $0.visualState == .active }) {
            return .active
        }
        if actors.values.contains(where: { $0.visualState == .cancelled }) {
            return .cancelled
        }
        if actors.values.contains(where: { $0.visualState == .completed }) {
            return .completed
        }
        return .quiet
    }

    public var activeActorCount: Int {
        actors.values.count { $0.visualState == .active }
    }

    public var liveActorCount: Int {
        actors.values.count { actor in
            actor.visualState == .active
                || actor.visualState == .attention
                || actor.visualState == .uncertain
        }
    }
}

public enum MotionMode: Equatable, Sendable {
    case drift
    case flow
    case wait
    case uncertain
    case ripple
    case cancelled
    case failed
}

public enum WorldEffect: Equatable, Sendable {
    case childStarted(actorId: String, parentActorId: String)
    case childCompleted(actorId: String, parentActorId: String)
    case topLevelCompleted
}

public struct WorldUpdate: Equatable, Sendable {
    public let state: WorldState
    public let effects: [WorldEffect]
    public let observationAccepted: Bool

    public init(state: WorldState, effects: [WorldEffect], observationAccepted: Bool) {
        self.state = state
        self.effects = effects
        self.observationAccepted = observationAccepted
    }
}

public struct WorldIntent: Equatable, Sendable {
    public let actorId: String
    public let seed: UInt64
    public let motion: MotionMode
    public let parentActorId: String?
    public let toolCategory: ToolCategory?
}

public extension WorldState {
    var intents: [WorldIntent] {
        orderedActors.map { actor in
            WorldIntent(
                actorId: actor.id,
                seed: actor.seed,
                motion: actor.visualState.motion,
                parentActorId: actor.parentActorId,
                toolCategory: actor.toolCategory
            )
        }
    }
}

private extension VisualState {
    var motion: MotionMode {
        switch self {
        case .quiet: .drift
        case .active: .flow
        case .attention: .wait
        case .uncertain: .uncertain
        case .completed: .ripple
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }
}
