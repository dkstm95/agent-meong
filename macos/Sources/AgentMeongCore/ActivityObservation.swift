import Foundation

public enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case sessionOpened = "session.opened"
    case turnStarted = "turn.started"
    case toolStarted = "tool.started"
    case toolFinished = "tool.finished"
    case approvalWaiting = "approval.waiting"
    case agentStarted = "agent.started"
    case agentFinished = "agent.finished"
    case turnStopping = "turn.stopping"
    case heartbeat
}

public enum ToolCategory: String, Codable, Sendable {
    case shell
    case edit
    case search
    case browser
    case other
}

public enum ActivityOutcome: String, Codable, Sendable {
    case success
    case failure
    case cancelled
}

public struct ActivityObservation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let eventId: String
    public let source: String
    public let sessionId: String
    public let actorId: String
    public let parentActorId: String?
    public let scopeId: String?
    public let occurredAt: Date
    public let kind: ActivityKind
    public let integrationVersion: String?
    public let integrationInstance: String?
    public let toolCategory: ToolCategory?
    public let outcome: ActivityOutcome?

    public init(
        eventId: String,
        source: String,
        sessionId: String,
        actorId: String,
        parentActorId: String? = nil,
        scopeId: String? = nil,
        occurredAt: Date,
        kind: ActivityKind,
        integrationVersion: String? = nil,
        integrationInstance: String? = nil,
        toolCategory: ToolCategory? = nil,
        outcome: ActivityOutcome? = nil
    ) {
        schemaVersion = 0
        self.eventId = eventId
        self.source = source
        self.sessionId = sessionId
        self.actorId = actorId
        self.parentActorId = parentActorId
        self.scopeId = scopeId
        self.occurredAt = occurredAt
        self.kind = kind
        self.integrationVersion = integrationVersion
        self.integrationInstance = integrationInstance
        self.toolCategory = toolCategory
        self.outcome = outcome
    }
}
