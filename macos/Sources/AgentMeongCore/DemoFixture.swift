import Foundation

public enum DemoFixture {
    public static func observations(at date: Date = .now) -> [ActivityObservation] {
        [
            observation("work-main", 0, .turnStarted, at: date),
            observation("work-child-a", 1, .agentStarted, parent: "work-main", at: date),
            observation("work-child-b", 2, .agentStarted, parent: "work-main", at: date),
            observation("waiting", 3, .approvalWaiting, at: date),
            observation("uncertain", 4, .turnStarted, age: 100, at: date),
            observation("complete", 5, .turnStopping, at: date),
            observation("failed", 6, .turnStopping, outcome: .failure, at: date),
        ]
    }

    private static func observation(
        _ actorId: String,
        _ offset: Int,
        _ kind: ActivityKind,
        parent: String? = nil,
        age: TimeInterval = 0,
        outcome: ActivityOutcome? = nil,
        at date: Date
    ) -> ActivityObservation {
        ActivityObservation(
            eventId: "demo-\(offset)",
            source: "demo",
            sessionId: "demo-session",
            actorId: actorId,
            parentActorId: parent,
            occurredAt: date.addingTimeInterval(-age - TimeInterval(offset) / 100),
            kind: kind,
            outcome: outcome
        )
    }
}
