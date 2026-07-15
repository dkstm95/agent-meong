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
require(priorityReducer.state.activeActorCount == 1, "active count is independent of aggregate state")

var duplicateReducer = WorldReducer()
duplicateReducer.apply(observation(id: "same", kind: .turnStarted))
duplicateReducer.apply(observation(
    id: "same",
    kind: .approvalWaiting,
    at: now.addingTimeInterval(10)
))
require(duplicateReducer.state.actors["actor"]?.visualState == .active, "duplicate is ignored")

var boundedDedupReducer = WorldReducer(deduplicationCapacity: 2)
boundedDedupReducer.apply(observation(id: "old", actor: "old", kind: .turnStarted))
boundedDedupReducer.apply(observation(id: "middle", actor: "middle", kind: .turnStarted))
boundedDedupReducer.apply(observation(id: "new", actor: "new", kind: .turnStarted))
boundedDedupReducer.apply(observation(
    id: "old",
    actor: "old",
    kind: .approvalWaiting,
    at: now.addingTimeInterval(1)
))
require(boundedDedupReducer.state.actors["old"]?.visualState == .attention, "dedup history is bounded")

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

var effectReducer = WorldReducer()
effectReducer.apply(observation(id: "main-a", actor: "main-a", session: "a", kind: .turnStarted))
effectReducer.apply(observation(id: "main-b", actor: "main-b", session: "b", kind: .turnStarted))
let partialCompletion = effectReducer.applyWithEffects(observation(
    id: "main-a-stop",
    actor: "main-a",
    session: "a",
    kind: .turnStopping,
    at: now.addingTimeInterval(1),
    outcome: .success
))
require(partialCompletion.state.aggregateState == .active, "one completed task leaves other task active")
require(partialCompletion.state.activeActorCount == 1, "one active task remains after partial completion")
require(partialCompletion.effects == [.topLevelCompleted], "accepted top-level stop emits completion")
let duplicateCompletion = effectReducer.applyWithEffects(observation(
    id: "main-a-stop",
    actor: "main-a",
    session: "a",
    kind: .turnStopping,
    at: now.addingTimeInterval(2),
    outcome: .success
))
require(duplicateCompletion.effects.isEmpty, "duplicate stop does not emit completion")
require(!duplicateCompletion.observationAccepted, "duplicate stop is reported as ignored")
let completedHeartbeat = effectReducer.applyWithEffects(observation(
    id: "main-a-heartbeat",
    actor: "main-a",
    session: "a",
    kind: .heartbeat,
    at: now.addingTimeInterval(3)
))
require(completedHeartbeat.effects.isEmpty, "completed heartbeat does not emit completion")
require(completedHeartbeat.observationAccepted, "new completed heartbeat remains an accepted observation")

var childEffectReducer = WorldReducer()
let childStart = ActivityObservation(
    eventId: "child-effect-start",
    source: "check",
    sessionId: "session",
    actorId: "child-effect",
    parentActorId: "main",
    scopeId: "turn-a",
    occurredAt: now,
    kind: .agentStarted
)
let childStartedUpdate = childEffectReducer.applyWithEffects(childStart)
require(
    childStartedUpdate.effects == [.childStarted(actorId: "child-effect", parentActorId: "main")],
    "accepted child start emits birth effect"
)
let childFinishedUpdate = childEffectReducer.applyWithEffects(ActivityObservation(
    eventId: "child-effect-stop",
    source: "check",
    sessionId: "session",
    actorId: "child-effect",
    parentActorId: "main",
    scopeId: "turn-a",
    occurredAt: now.addingTimeInterval(1),
    kind: .agentFinished,
    outcome: .success
))
require(
    childFinishedUpdate.effects == [.childCompleted(actorId: "child-effect", parentActorId: "main")],
    "accepted child stop emits absorption effect"
)
let completedChildHeartbeat = childEffectReducer.applyWithEffects(ActivityObservation(
    eventId: "child-effect-heartbeat",
    source: "check",
    sessionId: "session",
    actorId: "child-effect",
    parentActorId: "main",
    scopeId: "turn-a",
    occurredAt: now.addingTimeInterval(2),
    kind: .heartbeat
))
require(completedChildHeartbeat.effects.isEmpty, "completed child heartbeat does not repeat absorption")

var cancelledReducer = WorldReducer()
let cancelledUpdate = cancelledReducer.applyWithEffects(observation(
    id: "cancelled",
    kind: .turnStopping,
    outcome: .cancelled
))
require(cancelledUpdate.state.actors["actor"]?.visualState == .cancelled, "cancelled is not completed")
require(cancelledUpdate.effects.isEmpty, "cancelled stop does not emit completion")

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

var familyReducer = WorldReducer()
familyReducer.apply(observation(id: "family-main", actor: "family-main", scope: "scope", kind: .turnStarted))
familyReducer.apply(ActivityObservation(
    eventId: "family-child",
    source: "check",
    sessionId: "session",
    actorId: "family-child",
    parentActorId: "family-main",
    scopeId: "scope",
    occurredAt: now,
    kind: .agentStarted
))
familyReducer.apply(ActivityObservation(
    eventId: "other-child",
    source: "check",
    sessionId: "session",
    actorId: "other-child",
    parentActorId: "other-main",
    scopeId: "scope",
    occurredAt: now,
    kind: .agentStarted
))
familyReducer.apply(observation(
    id: "family-stop",
    actor: "family-main",
    scope: "scope",
    kind: .turnStopping,
    at: now.addingTimeInterval(1)
))
require(familyReducer.state.actors["family-child"]?.visualState == .uncertain, "parent settles descendants")
require(familyReducer.state.actors["other-child"]?.visualState == .active, "parent does not settle another family")

var attentionChildReducer = WorldReducer()
attentionChildReducer.apply(observation(
    id: "attention-main",
    actor: "attention-main",
    scope: "turn-a",
    kind: .turnStarted
))
attentionChildReducer.apply(ActivityObservation(
    eventId: "attention-child-start",
    source: "check",
    sessionId: "session",
    actorId: "attention-child",
    parentActorId: "attention-main",
    occurredAt: now,
    kind: .agentStarted
))
attentionChildReducer.apply(ActivityObservation(
    eventId: "attention-child-wait",
    source: "check",
    sessionId: "session",
    actorId: "attention-child",
    parentActorId: "attention-main",
    occurredAt: now.addingTimeInterval(1),
    kind: .approvalWaiting
))
attentionChildReducer.apply(observation(
    id: "attention-main-stop",
    actor: "attention-main",
    scope: "turn-a",
    kind: .turnStopping,
    at: now.addingTimeInterval(2)
))
require(
    attentionChildReducer.state.actors["attention-child"]?.visualState == .uncertain,
    "parent stop settles attention child without a scope"
)

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

print("AgentMeongCoreChecks: 35 checks passed")
