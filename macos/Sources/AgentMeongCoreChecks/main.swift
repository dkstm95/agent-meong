import AgentMeongCore
import Foundation

let now = Date(timeIntervalSince1970: 1_700_000_000)

func observation(
    id: String,
    actor: String = "actor",
    session: String = "session",
    scope: String? = nil,
    kind: ActivityKind,
    at date: Date? = nil,
    outcome: ActivityOutcome? = nil
) -> ActivityObservation {
    ActivityObservation(
        eventId: id,
        source: "check",
        sessionId: session,
        actorId: actor,
        scopeId: scope,
        occurredAt: date ?? now,
        kind: kind,
        outcome: outcome
    )
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
        exit(1)
    }
}

var transitionReducer = WorldReducer()
transitionReducer.apply(observation(id: "one", kind: .turnStarted))
require(transitionReducer.state.actors["actor"]?.visualState == .active, "turn starts active")

var priorityReducer = WorldReducer()
priorityReducer.apply(observation(id: "one", actor: "active", kind: .turnStarted))
priorityReducer.apply(observation(id: "two", actor: "waiting", kind: .approvalWaiting))
require(priorityReducer.state.aggregateState == .attention, "attention has priority")

var duplicateReducer = WorldReducer()
duplicateReducer.apply(observation(id: "same", kind: .turnStarted))
duplicateReducer.apply(observation(
    id: "same",
    kind: .approvalWaiting,
    at: now.addingTimeInterval(10)
))
require(duplicateReducer.state.actors["actor"]?.visualState == .active, "duplicate is ignored")

var expiryReducer = WorldReducer(staleInterval: 30, completedInterval: 4)
expiryReducer.apply(observation(id: "one", actor: "active", kind: .turnStarted))
expiryReducer.apply(observation(
    id: "two",
    actor: "done",
    session: "completed-session",
    kind: .turnStopping
))
expiryReducer.apply(observation(id: "three", actor: "waiting", kind: .approvalWaiting))
expiryReducer.expire(at: now.addingTimeInterval(31))
require(expiryReducer.state.actors["active"]?.visualState == .uncertain, "silent active actor becomes uncertain")
require(expiryReducer.state.actors["done"] == nil, "completed actor disappears")
require(expiryReducer.state.actors["waiting"]?.visualState == .attention, "waiting actor remains visible")

var failureReducer = WorldReducer()
failureReducer.apply(observation(
    id: "failed",
    kind: .turnStopping,
    outcome: .failure
))
failureReducer.expire(at: now.addingTimeInterval(29))
require(failureReducer.state.actors["actor"]?.visualState == .failed, "failed actor remains briefly visible")
failureReducer.expire(at: now.addingTimeInterval(31))
require(failureReducer.state.actors["actor"] == nil, "failed actor eventually disappears")

var heartbeatReducer = WorldReducer(staleInterval: 30)
heartbeatReducer.apply(observation(id: "start", kind: .turnStarted))
heartbeatReducer.expire(at: now.addingTimeInterval(31))
heartbeatReducer.apply(observation(id: "heartbeat", kind: .heartbeat, at: now.addingTimeInterval(32)))
require(heartbeatReducer.state.actors["actor"]?.visualState == .active, "heartbeat revives uncertain actor")

var settlingReducer = WorldReducer(uncertainInterval: 12, completedInterval: 8)
settlingReducer.apply(observation(
    id: "main-start",
    actor: "main",
    scope: "turn-a",
    kind: .turnStarted
))
settlingReducer.apply(ActivityObservation(
    eventId: "child-start",
    source: "check",
    sessionId: "session",
    actorId: "child",
    parentActorId: "main",
    scopeId: "turn-a",
    occurredAt: now,
    kind: .agentStarted
))
settlingReducer.apply(observation(
    id: "main-stop",
    actor: "main",
    scope: "turn-a",
    kind: .turnStopping
))
require(settlingReducer.state.actors["child"]?.visualState == .uncertain, "main stop settles missing child stop")
settlingReducer.expire(at: now.addingTimeInterval(13))
require(settlingReducer.state.actors["child"] == nil, "uncertain child eventually disappears")

var explicitStopReducer = WorldReducer()
explicitStopReducer.apply(ActivityObservation(
    eventId: "child-start",
    source: "check",
    sessionId: "session",
    actorId: "child",
    parentActorId: "main",
    scopeId: "turn-a",
    occurredAt: now,
    kind: .agentStarted
))
explicitStopReducer.apply(ActivityObservation(
    eventId: "child-stop",
    source: "check",
    sessionId: "session",
    actorId: "child",
    parentActorId: "main",
    scopeId: "turn-a",
    occurredAt: now.addingTimeInterval(1),
    kind: .agentFinished
))
require(explicitStopReducer.state.actors["child"]?.visualState == .completed, "explicit child stop completes child")

var oldTimeReducer = WorldReducer()
oldTimeReducer.apply(observation(id: "new", kind: .turnStarted, at: now.addingTimeInterval(10)))
oldTimeReducer.apply(observation(id: "old", kind: .approvalWaiting, at: now))
require(oldTimeReducer.state.actors["actor"]?.visualState == .active, "older event cannot regress actor")

var oldScopeReducer = WorldReducer()
oldScopeReducer.apply(observation(id: "turn-a", scope: "turn-a", kind: .turnStarted))
oldScopeReducer.apply(ActivityObservation(
    eventId: "turn-a-child",
    source: "check",
    sessionId: "session",
    actorId: "child",
    parentActorId: "actor",
    scopeId: "turn-a",
    occurredAt: now,
    kind: .agentStarted
))
oldScopeReducer.apply(observation(
    id: "turn-b",
    scope: "turn-b",
    kind: .turnStarted,
    at: now.addingTimeInterval(1)
))
require(oldScopeReducer.state.actors["child"]?.visualState == .uncertain, "new turn settles prior turn child")
oldScopeReducer.apply(observation(
    id: "late-stop",
    scope: "turn-a",
    kind: .turnStopping,
    at: now.addingTimeInterval(2)
))
require(oldScopeReducer.state.actors["actor"]?.visualState == .active, "old turn stop cannot override newer turn")

var firstOrder = WorldReducer()
var secondOrder = WorldReducer()
let eventA = observation(id: "a", actor: "a", kind: .turnStarted)
let eventB = observation(id: "b", actor: "b", kind: .approvalWaiting)
firstOrder.apply(eventA)
firstOrder.apply(eventB)
secondOrder.apply(eventB)
secondOrder.apply(eventA)
require(firstOrder.state.intents == secondOrder.state.intents, "intent order is deterministic")

let fixture = DemoFixture.observations(at: now)
require(fixture.count == 7, "demo contains only seven logical work actors")
require(fixture.allSatisfy { !$0.actorId.hasPrefix("ambient-") }, "demo has no fake ambient actors")

print("AgentMeongCoreChecks: 14 checks passed")
