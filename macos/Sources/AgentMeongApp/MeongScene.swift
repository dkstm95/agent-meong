import AgentMeongCore
import AppKit
import SpriteKit

struct SceneTransitionSummary: Equatable {
    var childBirths = 0
    var childAbsorptions = 0
    var workCompletions = 0
}

@MainActor
final class MeongScene: SKScene {
    private var actorNodes: [String: TadpoleNode] = [:]
    private var intentsById: [String: WorldIntent] = [:]
    private var identitySlots: [String: Int] = [:]
    private var lastUpdateTime: TimeInterval?
    private var fieldEnergy: CGFloat = 0
    private var targetFieldEnergy: CGFloat = 0
    private var reduceMotion = false

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = NSColor(srgbRed: 0.018, green: 0.026, blue: 0.055, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func sync(
        with intents: [WorldIntent],
        effects: [WorldEffect] = []
    ) -> SceneTransitionSummary {
        updateWorkloadEnergy(intents)
        intentsById = Dictionary(uniqueKeysWithValues: intents.map { ($0.actorId, $0) })
        removeMissingNodes(validIds: Set(intentsById.keys))

        let created = Set(intents.compactMap { ensureNode(for: $0) })
        let birthActorIds = Set(effects.compactMap { effect -> String? in
            guard case let .childStarted(actorId, _) = effect else { return nil }
            return actorId
        })
        let createdIntents = intents.filter { created.contains($0.actorId) }
        createdIntents.forEach { intent in
            if birthActorIds.contains(intent.actorId), !reduceMotion {
                placeAtParentEdge(intent)
            } else {
                placeNearParent(intent)
            }
        }
        intents.forEach(applyAppearance)

        var summary = SceneTransitionSummary()
        for actorId in birthActorIds where created.contains(actorId) {
            guard let node = actorNodes[actorId] else { continue }
            node.showBirth(reduceMotion: reduceMotion)
            summary.childBirths += 1
        }
        for effect in effects {
            switch effect {
            case let .childCompleted(actorId, parentActorId):
                guard
                    let child = actorNodes[actorId],
                    let parent = actorNodes[parentActorId]
                else { continue }
                if reduceMotion {
                    child.showStaticAbsorption(toward: parent.position)
                } else {
                    child.beginAbsorption()
                }
                parent.showAbsorptionReceipt(reduceMotion: reduceMotion)
                summary.childAbsorptions += 1
            case .topLevelCompleted:
                if !reduceMotion { showCompletionBreath() }
                summary.workCompletions += 1
            case .childStarted:
                continue
            }
        }
        return summary
    }

    func setReduceMotion(_ isEnabled: Bool) {
        guard reduceMotion != isEnabled else { return }
        reduceMotion = isEnabled
        intentsById.values.forEach(applyAppearance)
        if isEnabled {
            for intent in intentsById.values where intent.motion == .ripple {
                guard
                    let parentId = intent.parentActorId,
                    let parent = actorNodes[parentId],
                    let child = actorNodes[intent.actorId]
                else { continue }
                child.showStaticAbsorption(toward: parent.position)
            }
        }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        actorNodes.values.forEach { $0.position = bounded($0.position) }
    }

    override func update(_ currentTime: TimeInterval) {
        let delta = min(1.0 / 15.0, currentTime - (lastUpdateTime ?? currentTime))
        lastUpdateTime = currentTime
        guard delta > 0 else { return }
        updateFieldEnergy(delta: delta)

        let positions = actorNodes.mapValues(\.position)
        for intent in intentsById.values.sorted(by: { $0.actorId < $1.actorId }) {
            guard let node = actorNodes[intent.actorId] else { continue }
            move(node, for: intent, positions: positions, time: currentTime, delta: delta)
        }
    }

    private func ensureNode(for intent: WorldIntent) -> String? {
        guard actorNodes[intent.actorId] == nil else { return nil }
        var random = SeededRandom(seed: intent.seed)
        let baseRadius: CGFloat = intent.parentActorId == nil ? 5.1 : 3.8
        let node = TadpoleNode(
            radius: baseRadius + random.cgRange(-0.45, 0.45),
            color: color(for: intent),
            tailBend: random.cgRange(-3.5, 3.5),
            motionPhase: random.cgRange(0, .pi * 2),
            speedFactor: random.cgRange(0.84, 1.16)
        )
        node.position = randomPoint(seed: intent.seed)
        actorNodes[intent.actorId] = node
        addChild(node)
        return intent.actorId
    }

    private func placeNearParent(_ intent: WorldIntent) {
        guard
            let parentId = intent.parentActorId,
            let parent = actorNodes[parentId],
            let child = actorNodes[intent.actorId]
        else { return }
        var random = SeededRandom(seed: intent.seed ^ 0x94d049bb133111eb)
        child.position = bounded(CGPoint(
            x: parent.position.x + random.cgRange(-38, 38),
            y: parent.position.y + random.cgRange(-38, 38)
        ))
    }

    private func placeAtParentEdge(_ intent: WorldIntent) {
        guard
            let parentId = intent.parentActorId,
            let parent = actorNodes[parentId],
            let child = actorNodes[intent.actorId]
        else {
            placeNearParent(intent)
            return
        }
        var random = SeededRandom(seed: intent.seed ^ 0xd6e8feb86659fd93)
        let angle = random.cgRange(0, .pi * 2)
        let direction = CGVector(dx: cos(angle), dy: sin(angle))
        child.position = bounded(CGPoint(
            x: parent.position.x + direction.dx * 3,
            y: parent.position.y + direction.dy * 3
        ))
        child.velocity = scaled(direction, by: 11)
    }

    private func applyAppearance(_ intent: WorldIntent) {
        actorNodes[intent.actorId]?.apply(
            intent.motion,
            color: color(for: intent),
            reduceMotion: reduceMotion
        )
    }

    private func move(
        _ node: TadpoleNode,
        for intent: WorldIntent,
        positions: [String: CGPoint],
        time: TimeInterval,
        delta: TimeInterval
    ) {
        if
            intent.motion == .ripple,
            node.isAbsorbing,
            let parentId = intent.parentActorId,
            let parentPosition = positions[parentId]
        {
            node.updateAbsorption(toward: parentPosition, delta: delta)
            return
        }

        let speed = organicSpeed(for: node, motion: intent.motion, time: time)
        if speed == 0 {
            node.velocity = scaled(node.velocity, by: max(0, 1 - CGFloat(delta) * 4))
            node.position = bounded(CGPoint(
                x: node.position.x + node.velocity.dx * CGFloat(delta),
                y: node.position.y + node.velocity.dy * CGFloat(delta)
            ))
            return
        }

        var steering = wander(for: node, time: time)
        steering = added(steering, separation(from: intent.actorId, positions: positions))
        steering = added(steering, boundaryForce(at: node.position))
        steering = added(steering, familyForce(for: intent, positions: positions))

        let target = scaled(normalized(steering, fallback: node.velocity), by: speed)
        let blend = min(1, CGFloat(delta) * 1.7)
        let oldHeading = normalized(node.velocity)
        let newHeading = normalized(target)
        let lateral = oldHeading.dx * newHeading.dy - oldHeading.dy * newHeading.dx
        node.velocity = interpolated(node.velocity, target, amount: blend)
        node.position = bounded(CGPoint(
            x: node.position.x + node.velocity.dx * CGFloat(delta),
            y: node.position.y + node.velocity.dy * CGFloat(delta)
        ))
        if magnitude(node.velocity) > 0.5 {
            node.zRotation = atan2(node.velocity.dy, node.velocity.dx)
        }
        node.updateTail(
            at: CGFloat(time),
            lateralAcceleration: lateral,
            reduceMotion: reduceMotion
        )
    }

    private func wander(for node: TadpoleNode, time: TimeInterval) -> CGVector {
        let time = CGFloat(time)
        return CGVector(
            dx: cos(time * 0.53 + node.motionPhase)
                + 0.34 * cos(time * 0.19 + node.motionPhase * 1.71),
            dy: sin(time * 0.41 + node.motionPhase * 1.37)
                + 0.28 * sin(time * 0.23 + node.motionPhase * 0.83)
        )
    }

    private func separation(from actorId: String, positions: [String: CGPoint]) -> CGVector {
        guard let origin = positions[actorId] else { return .zero }
        return positions.reduce(into: CGVector.zero) { result, entry in
            guard entry.key != actorId else { return }
            let offset = vector(from: entry.value, to: origin)
            let distance = magnitude(offset)
            guard distance > 0, distance < 26 else { return }
            result = added(result, scaled(normalized(offset), by: (26 - distance) / 12))
        }
    }

    private func familyForce(for intent: WorldIntent, positions: [String: CGPoint]) -> CGVector {
        guard
            let parentId = intent.parentActorId,
            let child = positions[intent.actorId],
            let parent = positions[parentId]
        else { return .zero }
        let towardParent = vector(from: child, to: parent)
        let distance = magnitude(towardParent)
        if distance > 72 {
            return scaled(normalized(towardParent), by: min(2.4, (distance - 72) / 36))
        }
        if distance < 30 {
            return scaled(normalized(towardParent), by: -1.2)
        }
        return .zero
    }

    private func boundaryForce(at point: CGPoint) -> CGVector {
        let margin: CGFloat = 46
        var force = CGVector.zero
        if point.x < margin { force.dx += (margin - point.x) / 15 }
        if point.x > size.width - margin { force.dx -= (point.x - size.width + margin) / 15 }
        if point.y < margin { force.dy += (margin - point.y) / 15 }
        if point.y > size.height - margin { force.dy -= (point.y - size.height + margin) / 15 }
        return force
    }

    private func speed(for motion: MotionMode) -> CGFloat {
        switch motion {
        case .drift: 7
        case .flow: 24
        case .uncertain: 2.4
        case .wait, .ripple, .cancelled, .failed: 0
        }
    }

    private func organicSpeed(
        for node: TadpoleNode,
        motion: MotionMode,
        time: TimeInterval
    ) -> CGFloat {
        guard !reduceMotion else { return 0 }
        let time = CGFloat(time)
        let envelope = 0.78
            + 0.17 * sin(time * 0.31 + node.motionPhase)
            + 0.05 * sin(time * 0.73 + node.motionPhase * 1.43)
        return speed(for: motion) * node.speedFactor * max(0.52, envelope)
    }

    private func color(for intent: WorldIntent) -> NSColor {
        switch intent.motion {
        case .drift: NSColor(srgbRed: 0.60, green: 0.66, blue: 0.72, alpha: 1)
        case .flow: identityPalette[identitySlot(for: intent)]
        case .wait: NSColor(srgbRed: 0.93, green: 0.67, blue: 0.30, alpha: 1)
        case .uncertain: NSColor(srgbRed: 0.48, green: 0.53, blue: 0.62, alpha: 1)
        case .ripple: NSColor(srgbRed: 0.72, green: 0.66, blue: 0.96, alpha: 1)
        case .cancelled: NSColor(srgbRed: 0.46, green: 0.51, blue: 0.57, alpha: 1)
        case .failed: NSColor(srgbRed: 0.82, green: 0.38, blue: 0.42, alpha: 1)
        }
    }

    private func removeMissingNodes(validIds: Set<String>) {
        actorNodes.keys.filter { !validIds.contains($0) }.forEach { id in
            actorNodes.removeValue(forKey: id)?.removeFromParent()
            identitySlots.removeValue(forKey: id)
        }
    }

    private func identitySlot(for intent: WorldIntent) -> Int {
        if let slot = identitySlots[intent.actorId] { return slot }
        let used = Set(identitySlots.values)
        var slot = Int(intent.seed % UInt64(identityPalette.count))
        for _ in 0..<identityPalette.count where used.contains(slot) {
            slot = (slot + 1) % identityPalette.count
        }
        identitySlots[intent.actorId] = slot
        return slot
    }

    private var identityPalette: [NSColor] {
        [
            NSColor(srgbRed: 0.62, green: 0.88, blue: 0.96, alpha: 1),
            NSColor(srgbRed: 0.78, green: 0.72, blue: 0.96, alpha: 1),
            NSColor(srgbRed: 0.62, green: 0.91, blue: 0.79, alpha: 1),
            NSColor(srgbRed: 0.96, green: 0.82, blue: 0.70, alpha: 1),
            NSColor(srgbRed: 0.72, green: 0.81, blue: 0.98, alpha: 1),
            NSColor(srgbRed: 0.92, green: 0.72, blue: 0.84, alpha: 1),
            NSColor(srgbRed: 0.88, green: 0.91, blue: 0.72, alpha: 1),
            NSColor(srgbRed: 0.90, green: 0.91, blue: 0.94, alpha: 1),
        ]
    }

    private func updateWorkloadEnergy(_ intents: [WorldIntent]) {
        let liveCount = intents.count { intent in
            intent.motion == .flow || intent.motion == .wait || intent.motion == .uncertain
        }
        targetFieldEnergy = 1 - exp(-0.45 * CGFloat(liveCount))
    }

    private func updateFieldEnergy(delta: TimeInterval) {
        let blend = min(1, CGFloat(delta) * 0.5)
        fieldEnergy += (targetFieldEnergy - fieldEnergy) * blend
        backgroundColor = NSColor(
            srgbRed: 0.018 + fieldEnergy * 0.010,
            green: 0.026 + fieldEnergy * 0.014,
            blue: 0.055 + fieldEnergy * 0.018,
            alpha: 1
        )
    }

    private func showCompletionBreath() {
        childNode(withName: "completion-breath")?.removeFromParent()
        let breath = SKShapeNode(circleOfRadius: min(size.width, size.height) * 0.12)
        breath.name = "completion-breath"
        breath.position = CGPoint(x: size.width / 2, y: size.height / 2)
        breath.fillColor = NSColor.white.withAlphaComponent(0.018)
        breath.strokeColor = NSColor.white.withAlphaComponent(0.045)
        breath.lineWidth = 0.8
        breath.zPosition = -2
        breath.alpha = 0
        addChild(breath)
        breath.run(.sequence([
            .group([.fadeAlpha(to: 1, duration: 1.2), .scale(to: 2.8, duration: 2.8)]),
            .fadeOut(withDuration: 1.4),
            .removeFromParent(),
        ]))
    }

    private func randomPoint(seed: UInt64) -> CGPoint {
        var random = SeededRandom(seed: seed)
        return CGPoint(
            x: random.cgRange(46, max(47, size.width - 46)),
            y: random.cgRange(46, max(47, size.height - 46))
        )
    }

    private func bounded(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(14, point.x), size.width - 14),
            y: min(max(14, point.y), size.height - 14)
        )
    }
}

private func vector(from start: CGPoint, to end: CGPoint) -> CGVector {
    CGVector(dx: end.x - start.x, dy: end.y - start.y)
}

private func magnitude(_ vector: CGVector) -> CGFloat {
    hypot(vector.dx, vector.dy)
}

private func normalized(_ vector: CGVector, fallback: CGVector = CGVector(dx: 1, dy: 0)) -> CGVector {
    let length = magnitude(vector)
    if length > 0.0001 {
        return CGVector(dx: vector.dx / length, dy: vector.dy / length)
    }
    let fallbackLength = max(0.0001, magnitude(fallback))
    return CGVector(dx: fallback.dx / fallbackLength, dy: fallback.dy / fallbackLength)
}

private func added(_ first: CGVector, _ second: CGVector) -> CGVector {
    CGVector(dx: first.dx + second.dx, dy: first.dy + second.dy)
}

private func scaled(_ vector: CGVector, by scalar: CGFloat) -> CGVector {
    CGVector(dx: vector.dx * scalar, dy: vector.dy * scalar)
}

private func interpolated(_ first: CGVector, _ second: CGVector, amount: CGFloat) -> CGVector {
    CGVector(
        dx: first.dx + (second.dx - first.dx) * amount,
        dy: first.dy + (second.dy - first.dy) * amount
    )
}
