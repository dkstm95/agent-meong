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
    integrationInstance: String? = nil,
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
        integrationInstance: integrationInstance,
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

require(
    ConnectionReviewRefreshPolicy.delay(afterCompletedAttempts: 0) == 1
        && ConnectionReviewRefreshPolicy.delay(afterCompletedAttempts: 4) == 24,
    "connection review refresh starts quickly and reaches the steady cadence"
)
require(
    ConnectionReviewRefreshPolicy.delay(afterCompletedAttempts: 4) == 24
        && ConnectionReviewRefreshPolicy.delay(afterCompletedAttempts: 5) == nil,
    "connection review refresh stops after a bounded approval-check burst"
)

var priorityReducer = WorldReducer()
priorityReducer.apply(observation(id: "one", actor: "active", kind: .turnStarted))
priorityReducer.apply(observation(id: "two", actor: "waiting", kind: .approvalWaiting))
require(priorityReducer.state.aggregateState == .attention, "attention has priority")
require(priorityReducer.state.activeActorCount == 1, "active count is independent of aggregate state")
require(priorityReducer.state.attentionActorCount == 1, "attention count is exposed for accessibility")
require(priorityReducer.state.uncertainActorCount == 0, "uncertain count starts empty")
require(priorityReducer.state.failedActorCount == 0, "failure count starts empty")

var stateCountReducer = WorldReducer()
stateCountReducer.apply(observation(
    id: "state-count-quiet",
    actor: "quiet",
    session: "quiet",
    kind: .sessionOpened
))
stateCountReducer.apply(observation(
    id: "state-count-active",
    actor: "active",
    session: "active",
    kind: .turnStarted
))
stateCountReducer.apply(observation(
    id: "state-count-attention",
    actor: "attention",
    session: "attention",
    kind: .approvalWaiting
))
stateCountReducer.apply(observation(
    id: "state-count-uncertain",
    actor: "uncertain",
    session: "uncertain",
    kind: .turnStarted,
    at: now.addingTimeInterval(-91)
))
stateCountReducer.apply(observation(
    id: "state-count-finished",
    actor: "finished",
    session: "finished",
    kind: .turnStopping
))
stateCountReducer.apply(observation(
    id: "state-count-completed",
    actor: "completed",
    session: "completed",
    kind: .turnStopping,
    outcome: .success
))
stateCountReducer.apply(observation(
    id: "state-count-cancelled",
    actor: "cancelled",
    session: "cancelled",
    kind: .turnStopping,
    outcome: .cancelled
))
stateCountReducer.apply(observation(
    id: "state-count-failed",
    actor: "failed",
    session: "failed",
    kind: .turnStopping,
    outcome: .failure
))
stateCountReducer.expire(at: now)
let stateCounts = VisualState.allCases.map { stateCountReducer.state.actorCount(for: $0) }
require(stateCounts == Array(repeating: 1, count: VisualState.allCases.count), "every visual state has an independent actor count")
require(stateCountReducer.state.quietActorCount == 1, "quiet count is exposed for accessibility")
require(stateCountReducer.state.activeActorCount == 1, "active count is exposed for accessibility")
require(stateCountReducer.state.attentionActorCount == 1, "attention count remains independent")
require(stateCountReducer.state.uncertainActorCount == 1, "uncertain count is exposed for accessibility")
require(stateCountReducer.state.finishedActorCount == 1, "neutral finished count is exposed for accessibility")
require(stateCountReducer.state.completedActorCount == 1, "completed count is exposed for accessibility")
require(stateCountReducer.state.cancelledActorCount == 1, "cancelled count is exposed for accessibility")
require(stateCountReducer.state.failedActorCount == 1, "failed count remains independent")
require(stateCountReducer.state.liveActorCount == 3, "live count includes only active attention and uncertain actors")
require(
    stateCounts.reduce(0, +) == stateCountReducer.state.orderedActors.count,
    "state counts cover every observed actor exactly once"
)
let emptyWorld = WorldState()
require(emptyWorld.aggregateState == .quiet, "empty world remains visually quiet")
require(emptyWorld.quietActorCount == 0, "empty-world quiet does not invent an actor")
require(
    VisualState.allCases.allSatisfy { emptyWorld.actorCount(for: $0) == 0 },
    "empty world reports zero actors for every state"
)

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
require(
    expiryReducer.state.actors["active"]?.lastObservedAt == now.addingTimeInterval(30),
    "uncertain transition keeps the observation-time expiry boundary"
)
require(expiryReducer.state.actors["done"] == nil, "finished actor disappears")
require(expiryReducer.state.actors["waiting"]?.visualState == .attention, "waiting actor remains visible")

var lateExpiryReducer = WorldReducer(staleInterval: 30, uncertainInterval: 12)
lateExpiryReducer.apply(observation(id: "late", kind: .turnStarted))
lateExpiryReducer.expire(at: now.addingTimeInterval(43))
require(lateExpiryReducer.state.actors["actor"] == nil, "late expiry does not revive ancient active state")

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
let neutralChildStop = explicitStopReducer.applyWithEffects(ActivityObservation(
    eventId: "child-stop",
    source: "check",
    sessionId: "session",
    actorId: "child",
    parentActorId: "main",
    scopeId: "turn-a",
    occurredAt: now.addingTimeInterval(1),
    kind: .agentFinished
))
require(
    neutralChildStop.state.actors["child"]?.visualState == .finished,
    "outcome-free child stop records only that the child finished"
)
require(
    neutralChildStop.effects == [.childFinished(actorId: "child", parentActorId: "main")],
    "outcome-free child stop emits a neutral return effect"
)

var neutralEffectReducer = WorldReducer()
let neutralTopLevelStop = neutralEffectReducer.applyWithEffects(observation(
    id: "neutral-top-level-stop",
    kind: .turnStopping
))
require(
    neutralTopLevelStop.state.actors["actor"]?.visualState == .finished,
    "outcome-free top-level stop does not claim success"
)
require(
    neutralTopLevelStop.effects == [.topLevelFinished(actorId: "actor")],
    "outcome-free top-level stop emits a neutral end signal"
)

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
require(
    partialCompletion.effects == [.topLevelCompleted(actorId: "main-a")],
    "accepted top-level stop emits actor-specific completion"
)
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
require(
    childFinishedUpdate.state.actors["child-effect"]?.visualState == .completed,
    "explicit success remains a completed child"
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
require(
    cancelledUpdate.effects == [.topLevelFinished(actorId: "actor")],
    "cancelled stop still emits a neutral work-end signal"
)

var failedChildReducer = WorldReducer()
failedChildReducer.apply(ActivityObservation(
    eventId: "failed-child-start",
    source: "check",
    sessionId: "session",
    actorId: "failed-child",
    parentActorId: "main",
    scopeId: "turn-a",
    occurredAt: now,
    kind: .agentStarted
))
let failedChildUpdate = failedChildReducer.applyWithEffects(ActivityObservation(
    eventId: "failed-child-stop",
    source: "check",
    sessionId: "session",
    actorId: "failed-child",
    parentActorId: "main",
    scopeId: "turn-a",
    occurredAt: now.addingTimeInterval(1),
    kind: .agentFinished,
    outcome: .failure
))
require(
    failedChildUpdate.effects == [.childFinished(actorId: "failed-child", parentActorId: "main")],
    "failed child still returns to its parent without claiming success"
)

var toolEffectReducer = WorldReducer()
let toolStartedUpdate = toolEffectReducer.applyWithEffects(ActivityObservation(
    eventId: "tool-effect-start",
    source: "check",
    sessionId: "session",
    actorId: "tool-actor",
    scopeId: "turn-a",
    occurredAt: now,
    kind: .toolStarted,
    toolCategory: .shell
))
require(
    toolStartedUpdate.effects == [.toolStarted(actorId: "tool-actor", category: .shell)],
    "accepted tool start emits one actor-specific transient effect"
)
require(
    toolStartedUpdate.state.actors["tool-actor"]?.visualState == .active,
    "tool start records observed actor activity"
)
require(
    toolStartedUpdate.state.actors["tool-actor"]?.toolCategory == nil,
    "tool start does not claim a durable active tool"
)
let toolFinishedUpdate = toolEffectReducer.applyWithEffects(ActivityObservation(
    eventId: "tool-effect-finish",
    source: "check",
    sessionId: "session",
    actorId: "tool-actor",
    scopeId: "turn-a",
    occurredAt: now.addingTimeInterval(1),
    kind: .toolFinished,
    toolCategory: .shell
))
require(
    toolFinishedUpdate.effects == [.toolFinished(actorId: "tool-actor", category: .shell)],
    "accepted tool finish emits one actor-specific transient effect"
)
require(
    toolFinishedUpdate.state.actors["tool-actor"]?.toolCategory == nil,
    "tool finish leaves no durable tool category"
)
let duplicateToolFinish = toolEffectReducer.applyWithEffects(ActivityObservation(
    eventId: "tool-effect-finish",
    source: "check",
    sessionId: "session",
    actorId: "tool-actor",
    scopeId: "turn-a",
    occurredAt: now.addingTimeInterval(2),
    kind: .toolFinished,
    toolCategory: .shell
))
require(!duplicateToolFinish.observationAccepted, "duplicate tool finish is rejected")
require(duplicateToolFinish.effects.isEmpty, "duplicate tool finish emits no transient effect")

var terminalRaceReducer = WorldReducer()
terminalRaceReducer.apply(observation(id: "race-start", scope: "turn-a", kind: .turnStarted))
terminalRaceReducer.apply(observation(
    id: "race-stop",
    scope: "turn-a",
    kind: .turnStopping,
    at: now.addingTimeInterval(1)
))
let lateToolUpdate = terminalRaceReducer.applyWithEffects(observation(
    id: "race-late-tool",
    scope: "turn-a",
    kind: .toolFinished,
    at: now.addingTimeInterval(2)
))
require(!lateToolUpdate.observationAccepted, "late same-turn tool event cannot revive finished work")
require(lateToolUpdate.effects.isEmpty, "rejected late tool event emits no transient effect")
require(
    lateToolUpdate.state.actors["actor"]?.visualState == .finished,
    "finished work stays terminal after a late tool event"
)

var resumedChildReducer = WorldReducer()
resumedChildReducer.apply(ActivityObservation(
    eventId: "resumed-child-start",
    source: "check",
    sessionId: "session",
    actorId: "resumed-child",
    parentActorId: "main",
    scopeId: "child-turn-a",
    occurredAt: now,
    kind: .agentStarted
))
resumedChildReducer.apply(ActivityObservation(
    eventId: "resumed-child-stop",
    source: "check",
    sessionId: "session",
    actorId: "resumed-child",
    parentActorId: "main",
    scopeId: "child-turn-a",
    occurredAt: now.addingTimeInterval(1),
    kind: .agentFinished
))
let resumedChildTool = resumedChildReducer.applyWithEffects(ActivityObservation(
    eventId: "resumed-child-tool",
    source: "check",
    sessionId: "session",
    actorId: "resumed-child",
    parentActorId: "main",
    scopeId: "child-turn-b",
    occurredAt: now.addingTimeInterval(2),
    kind: .toolStarted,
    toolCategory: .shell
))
require(resumedChildTool.observationAccepted, "a resumed child's new scoped work is accepted")
require(
    resumedChildTool.state.actors["resumed-child"]?.visualState == .active,
    "a resumed child becomes active again"
)
require(
    resumedChildTool.state.actors["resumed-child"]?.parentActorId == "main",
    "a resumed child keeps its observed parent"
)

var unscopedCycleReducer = WorldReducer()
unscopedCycleReducer.apply(observation(id: "unscoped-first", kind: .turnStarted))
unscopedCycleReducer.apply(observation(
    id: "unscoped-stop",
    kind: .turnStopping,
    at: now.addingTimeInterval(1)
))
let unscopedSecondTurn = unscopedCycleReducer.applyWithEffects(observation(
    id: "unscoped-second",
    kind: .turnStarted,
    at: now.addingTimeInterval(2)
))
require(unscopedSecondTurn.observationAccepted, "unscoped source can start a later turn")
require(
    unscopedSecondTurn.state.actors["actor"]?.visualState == .active,
    "later unscoped turn reactivates the logical actor"
)

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

var checkpointReducer = WorldReducer()
checkpointReducer.apply(observation(id: "checkpoint-active", actor: "active", kind: .turnStarted))
checkpointReducer.apply(observation(id: "checkpoint-wait", actor: "waiting", kind: .approvalWaiting))
checkpointReducer.apply(observation(
    id: "checkpoint-finished",
    actor: "finished",
    kind: .turnStopping
))
checkpointReducer.apply(observation(
    id: "checkpoint-complete",
    actor: "complete",
    kind: .turnStopping,
    outcome: .success
))
checkpointReducer.apply(observation(
    id: "checkpoint-failed",
    actor: "failed",
    kind: .turnStopping,
    outcome: .failure
))
let checkpoint = WorldCheckpoint(state: checkpointReducer.state)
require(
    checkpoint.actors.map(\.id) == ["active", "waiting"],
    "restart checkpoint contains only live actor metadata"
)
let checkpointData = try JSONEncoder().encode(checkpoint)
let decodedCheckpoint = try JSONDecoder().decode(WorldCheckpoint.self, from: checkpointData)
require(decodedCheckpoint == checkpoint, "restart checkpoint round-trips deterministically")

let checkpointDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("agent-meong-core-checkpoint-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: checkpointDirectory) }
let checkpointURL = checkpointDirectory.appendingPathComponent("world.json")
let checkpointStore = WorldCheckpointStore(fileURL: checkpointURL)
try checkpointStore.save(checkpointReducer.state)
let loadedCheckpoint = try checkpointStore.load()
require(loadedCheckpoint == checkpoint, "durable checkpoint store round-trips live state")
let checkpointMode = try FileManager.default.attributesOfItem(atPath: checkpointURL.path)[.posixPermissions]
    as? NSNumber
require(checkpointMode?.intValue == 0o600, "durable checkpoint is user-readable only")
let undersizedStore = WorldCheckpointStore(fileURL: checkpointURL, maximumByteCount: 1)
var rejectedOversizedCheckpoint = false
do {
    try undersizedStore.save(checkpointReducer.state)
} catch WorldCheckpointStoreError.checkpointTooLarge {
    rejectedOversizedCheckpoint = true
}
require(rejectedOversizedCheckpoint, "oversized checkpoint update is rejected")
require(
    !FileManager.default.fileExists(atPath: checkpointURL.path),
    "failed checkpoint update removes the older live snapshot"
)
try checkpointStore.save(checkpointReducer.state)
try checkpointStore.save(WorldState())
require(!FileManager.default.fileExists(atPath: checkpointURL.path), "empty world removes durable checkpoint")
try FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)
try Data("not-json".utf8).write(to: checkpointURL)
var rejectedCorruptCheckpoint = false
do {
    _ = try checkpointStore.load()
} catch {
    rejectedCorruptCheckpoint = true
}
require(rejectedCorruptCheckpoint, "corrupt durable checkpoint is rejected")

var restoredReducer = WorldReducer(staleInterval: 30, uncertainInterval: 12, attentionInterval: 60)
restoredReducer.restore(decodedCheckpoint, at: now.addingTimeInterval(10))
require(restoredReducer.state.actors["active"]?.visualState == .active, "recent active actor restores")
require(restoredReducer.state.actors["waiting"]?.visualState == .attention, "recent attention actor restores")
require(restoredReducer.state.actors["finished"] == nil, "finished actor never restores")
require(restoredReducer.state.actors["complete"] == nil, "completed actor never restores")
require(restoredReducer.state.actors["failed"] == nil, "failed actor never restores")

var agingRestoreReducer = WorldReducer(staleInterval: 30, uncertainInterval: 12)
agingRestoreReducer.restore(decodedCheckpoint, at: now.addingTimeInterval(35))
require(
    agingRestoreReducer.state.actors["active"]?.visualState == .uncertain,
    "restored active actor spends only its remaining uncertain TTL"
)
require(
    agingRestoreReducer.state.actors["active"]?.lastObservedAt == now.addingTimeInterval(30),
    "restore preserves the original stale boundary"
)
agingRestoreReducer.restore(decodedCheckpoint, at: now.addingTimeInterval(43))
require(agingRestoreReducer.state.actors["active"] == nil, "expired active actor is not restored")

var futureCheckpointReducer = WorldReducer()
futureCheckpointReducer.apply(observation(
    id: "future",
    actor: "future",
    kind: .turnStarted,
    at: now.addingTimeInterval(1)
))
var futureRestoreReducer = WorldReducer()
futureRestoreReducer.restore(WorldCheckpoint(state: futureCheckpointReducer.state), at: now)
require(futureRestoreReducer.state.actors.isEmpty, "future-dated checkpoint actor is rejected")

var unsupportedRestoreReducer = WorldReducer()
unsupportedRestoreReducer.restore(
    WorldCheckpoint(schemaVersion: 999, actors: decodedCheckpoint.actors),
    at: now
)
require(unsupportedRestoreReducer.state.actors.isEmpty, "unsupported checkpoint schema is rejected")

var ownershipReducer = WorldReducer()
ownershipReducer.apply(observation(
    id: "ownership-default-one",
    actor: "default-one",
    session: "default-session",
    kind: .turnStarted,
    integrationInstance: "default-instance"
))
ownershipReducer.apply(observation(
    id: "ownership-custom",
    actor: "custom",
    session: "custom-session",
    kind: .turnStarted,
    integrationInstance: "custom-instance"
))
ownershipReducer.apply(observation(
    id: "ownership-default-two",
    actor: "default-two",
    session: "default-session",
    kind: .approvalWaiting,
    integrationInstance: "default-instance"
))
ownershipReducer.apply(observation(
    id: "ownership-unknown",
    actor: "unknown",
    session: "unknown-session",
    kind: .turnStarted
))
require(
    ownershipReducer.state.actors["default-one"]?.integrationInstance
        == "default-instance",
    "actor state keeps privacy-safe integration ownership"
)
ownershipReducer.apply(observation(
    id: "ownership-default-without-repeat",
    actor: "default-one",
    session: "default-session",
    kind: .turnStopping
))
require(
    ownershipReducer.state.actors["default-one"]?.integrationInstance
        == "default-instance",
    "owner-less updates do not erase known integration ownership"
)
require(
    ownershipReducer.state.knownIntegrationInstance(for: "default-one")
        == "default-instance",
    "completion receipts can resolve ownership after an owner-less terminal event"
)
let removedDefaultActors = ownershipReducer.removeActors(
    integrationInstance: "default-instance"
)
require(
    removedDefaultActors == Set(["default-one", "default-two"]),
    "removing an integration returns only its actor IDs"
)
require(
    ownershipReducer.state.actors["default-one"] == nil
        && ownershipReducer.state.actors["default-two"] == nil,
    "default integration actors are removed"
)
require(
    ownershipReducer.state.actors["custom"]?.integrationInstance == "custom-instance",
    "custom integration actor survives default removal"
)
require(
    ownershipReducer.state.actors["unknown"] != nil,
    "unknown ownership survives named integration removal"
)
var reverseOwnershipReducer = WorldReducer()
reverseOwnershipReducer.apply(observation(
    id: "reverse-default",
    actor: "reverse-default",
    session: "reverse-default-session",
    kind: .turnStarted,
    integrationInstance: "default-instance"
))
reverseOwnershipReducer.apply(observation(
    id: "reverse-custom",
    actor: "reverse-custom",
    session: "reverse-custom-session",
    kind: .turnStarted,
    integrationInstance: "custom-instance"
))
reverseOwnershipReducer.removeActors(integrationInstance: "default-instance")
require(
    reverseOwnershipReducer.state.actors["reverse-default"] == nil,
    "default actor is removed when custom was observed last"
)
require(
    reverseOwnershipReducer.state.actors["reverse-custom"]?.integrationInstance
        == "custom-instance",
    "custom actor survives when custom was observed last"
)
let ownershipCheckpoint = WorldCheckpoint(state: ownershipReducer.state)
let ownershipCheckpointData = try JSONEncoder().encode(ownershipCheckpoint)
let decodedOwnershipCheckpoint = try JSONDecoder().decode(
    WorldCheckpoint.self,
    from: ownershipCheckpointData
)
require(
    decodedOwnershipCheckpoint.actors.first(where: { $0.id == "custom" })?
        .integrationInstance == "custom-instance",
    "restart checkpoint preserves integration ownership"
)

var confirmationLedger = ConnectionConfirmationLedger()
confirmationLedger.record(
    instanceID: "custom-instance",
    definitionID: "definition",
    at: now
)
confirmationLedger.record(
    instanceID: "default-instance",
    definitionID: "definition",
    at: now.addingTimeInterval(1)
)
require(
    confirmationLedger.latest?.instanceID == "default-instance",
    "confirmation ledger selects the most recent integration"
)
require(
    confirmationLedger.remove(instanceID: "default-instance"),
    "confirmation ledger removes one named integration"
)
require(
    confirmationLedger.latest?.instanceID == "custom-instance",
    "removing default confirmation reveals the earlier custom confirmation"
)
var reverseConfirmationLedger = ConnectionConfirmationLedger()
reverseConfirmationLedger.record(
    instanceID: "default-instance",
    definitionID: "definition",
    at: now
)
reverseConfirmationLedger.record(
    instanceID: "custom-instance",
    definitionID: "definition",
    at: now.addingTimeInterval(1)
)
require(
    reverseConfirmationLedger.remove(instanceID: "default-instance")
        && reverseConfirmationLedger.latest?.instanceID == "custom-instance",
    "custom confirmation survives default removal when custom was observed last"
)
require(
    confirmationLedger.hasConfirmation(excluding: "default-instance")
        && reverseConfirmationLedger.hasConfirmation(excluding: "default-instance"),
    "separate confirmations are found independently of observation order"
)
confirmationLedger.record(
    instanceID: "custom-instance",
    definitionID: "older-definition",
    at: now.addingTimeInterval(-1)
)
require(
    confirmationLedger.latest?.definitionID == "definition",
    "older observations do not replace a newer confirmation"
)
let confirmationData = try JSONEncoder().encode(confirmationLedger)
let decodedConfirmationLedger = try JSONDecoder().decode(
    ConnectionConfirmationLedger.self,
    from: confirmationData
)
require(
    decodedConfirmationLedger == confirmationLedger,
    "confirmation ledger round-trips"
)
var boundedConfirmationLedger = ConnectionConfirmationLedger()
for index in 0..<(ConnectionConfirmationLedger.maximumEntryCount + 3) {
    boundedConfirmationLedger.record(
        instanceID: "instance-\(index)",
        definitionID: nil,
        at: now.addingTimeInterval(TimeInterval(index))
    )
}
require(
    boundedConfirmationLedger.entries.count
        == ConnectionConfirmationLedger.maximumEntryCount,
    "confirmation ledger stays bounded"
)
require(
    boundedConfirmationLedger.confirmation(instanceID: "instance-0") == nil
        && boundedConfirmationLedger.confirmation(
            instanceID: "instance-\(ConnectionConfirmationLedger.maximumEntryCount + 2)"
        ) != nil,
    "bounded confirmation ledger evicts oldest entries and keeps newest entries"
)

let fixture = DemoFixture.observations(at: now)
require(fixture.count == 7, "demo contains only seven logical work actors")
require(fixture.allSatisfy { !$0.actorId.hasPrefix("ambient-") }, "demo has no fake ambient actors")

print("AgentMeongCoreChecks: passed")
