import AgentMeongCore
import AppKit
import SpriteKit

struct SceneTransitionSummary: Equatable {
    var childBirths = 0
    var childAbsorptions = 0
    var workEndings = 0
    var toolStarts = 0
    var toolFinishes = 0
}

enum CompletionReceiptKind: Equatable {
    case finished
    case completed
}

@MainActor
final class MeongScene: SKScene {
    private struct CompletionReceipt {
        let actorId: String
        let kind: CompletionReceiptKind
        let color: NSColor
        let position: CGPoint
    }

    private static let completionReceiptNodeName = "completion-receipt"
    private static let completionReceiptGhostNodeName = "completion-receipt-ghost"
    private static let completionReceiptFinishedNodeName = "completion-receipt-finished"
    private static let completionReceiptInnerHaloNodeName = "completion-receipt-inner-halo"
    private static let completionReceiptOuterHaloNodeName = "completion-receipt-outer-halo"
    private static let completionReceiptColorKey = "completion-receipt-color"
    private static let workEndRippleNodeName = "work-end-ripple"
    private static let workEndRippleColorKey = "work-end-ripple-color"
    private static let maximumCompletionReceiptCount = 4
    private static let actorBoundaryMargin: CGFloat = 36
    private static let completionReceiptBoundaryMargin: CGFloat = 26
    private static let completionReceiptMinimumSeparation: CGFloat = 36

    private var actorNodes: [String: TadpoleNode] = [:]
    private var intentsById: [String: WorldIntent] = [:]
    private var lastUpdateTime: TimeInterval?
    private var fieldEnergy: CGFloat = 0
    private var targetFieldEnergy: CGFloat = 0
    private var reduceMotion = false
    private var increaseContrast = false
    private var completionReceipts: [CompletionReceipt] = []

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
            case let .childFinished(actorId, parentActorId),
                let .childCompleted(actorId, parentActorId):
                guard
                    let child = actorNodes[actorId],
                    let parent = actorNodes[parentActorId]
                else { continue }
                showWorkEndRipple(for: child)
                if reduceMotion {
                    child.showStaticAbsorption(toward: parent.position)
                } else {
                    child.beginAbsorption()
                }
                parent.showAbsorptionReceipt(reduceMotion: reduceMotion)
                summary.childAbsorptions += 1
            case let .toolStarted(actorId, category):
                if showToolStarted(for: actorId, category: category) {
                    summary.toolStarts += 1
                }
            case let .toolFinished(actorId, category):
                if showToolFinished(for: actorId, category: category) {
                    summary.toolFinishes += 1
                }
            case let .topLevelFinished(actorId),
                let .topLevelCompleted(actorId):
                if let node = actorNodes[actorId] {
                    showWorkEndRipple(for: node)
                }
                if !reduceMotion { showWorkEndBreath() }
                summary.workEndings += 1
            case .childStarted:
                continue
            }
        }
        return summary
    }

    @discardableResult
    func showToolStarted(for actorId: String, category: ToolCategory?) -> Bool {
        guard let node = actorNodes[actorId] else { return false }
        node.showToolImpulse(
            category: category,
            started: true,
            reduceMotion: reduceMotion,
            increaseContrast: increaseContrast
        )
        return true
    }

    @discardableResult
    func showToolFinished(for actorId: String, category: ToolCategory?) -> Bool {
        guard let node = actorNodes[actorId] else { return false }
        node.showToolImpulse(
            category: category,
            started: false,
            reduceMotion: reduceMotion,
            increaseContrast: increaseContrast
        )
        return true
    }

    /// Captures a privacy-safe visual receipt while the terminal actor is still
    /// present in the world. The opaque actor ID is used only as an in-memory
    /// deduplication key and is never rendered or exposed as accessibility text.
    func registerCompletionReceipt(
        for actorId: String,
        kind: CompletionReceiptKind
    ) {
        let snapshot = completionReceiptSnapshot(for: actorId, kind: kind)
        completionReceipts.removeAll { $0.actorId == actorId }
        completionReceipts.append(snapshot)
        if completionReceipts.count > Self.maximumCompletionReceiptCount {
            completionReceipts.removeFirst(
                completionReceipts.count - Self.maximumCompletionReceiptCount
            )
        }
    }

    /// Presents all unacknowledged receipts. Repeated calls replace the current
    /// receipt layer rather than stacking duplicate animations.
    @discardableResult
    func presentCompletionReceipts() -> Int {
        removePresentedCompletionReceipts()
        var occupiedPositions: [CGPoint] = []
        for receipt in completionReceipts {
            let position = resolvedCompletionReceiptPosition(
                preferred: receipt.position,
                occupied: occupiedPositions
            )
            occupiedPositions.append(position)
            addCompletionReceiptNode(receipt, at: position)
        }
        return completionReceipts.count
    }

    /// Marks the receipts as observed without cutting short their current visual.
    func acknowledgeCompletionReceipts() {
        completionReceipts.removeAll(keepingCapacity: true)
    }

    /// Clears both unacknowledged state and any receipt currently on screen.
    func clearCompletionReceipts() {
        acknowledgeCompletionReceipts()
        removePresentedCompletionReceipts()
    }

    var pendingCompletionReceiptCount: Int {
        completionReceipts.count
    }

    func setReduceMotion(_ isEnabled: Bool) {
        guard reduceMotion != isEnabled else { return }
        reduceMotion = isEnabled
        intentsById.values.forEach(applyAppearance)
        settleTerminalChildrenAfterPresentationReset()
        if isEnabled {
            childNode(withName: "work-end-breath")?.removeFromParent()
            presentedWorkEndRippleNodes.forEach { $0.removeFromParent() }
            actorNodes.values.forEach { $0.velocity = .zero }
            presentedCompletionReceiptNodes.forEach(settleCompletionReceiptForReduceMotion)
            updateFieldEnergy(delta: 0)
        }
    }

    func setIncreaseContrast(_ isEnabled: Bool) {
        guard increaseContrast != isEnabled else { return }
        increaseContrast = isEnabled
        intentsById.values.forEach(applyAppearance)
        settleTerminalChildrenAfterPresentationReset()
        presentedWorkEndRippleNodes.forEach(updateWorkEndRippleAppearance)
        presentedCompletionReceiptNodes.forEach(updateCompletionReceiptAppearance)
    }

    /// A transient effect that was already visible must not resume as if it
    /// were a new observation after the popover has spent time closed.
    func discardTransientPresentation() {
        childNode(withName: "work-end-breath")?.removeFromParent()
        presentedWorkEndRippleNodes.forEach { $0.removeFromParent() }
        removePresentedCompletionReceipts()
        actorNodes.values.forEach { $0.discardTransientPresentation() }
        settleTerminalChildrenAfterPresentationReset()
    }

    /// Presentation resets stop SpriteKit actions. Keep an already terminal
    /// child absorbed rather than replaying or undoing its lifecycle transition
    /// when an accessibility display setting changes.
    private func settleTerminalChildrenAfterPresentationReset() {
        let terminalChildren = intentsById.values.filter {
            $0.parentActorId != nil
                && [.finished, .ripple, .cancelled, .failed].contains($0.motion)
        }.sorted {
            let leftDepth = familyDepth(for: $0)
            let rightDepth = familyDepth(for: $1)
            return leftDepth == rightDepth
                ? $0.actorId < $1.actorId
                : leftDepth < rightDepth
        }
        for intent in terminalChildren {
            guard
                let parentId = intent.parentActorId,
                let parent = actorNodes[parentId],
                let child = actorNodes[intent.actorId]
            else { continue }
            child.showStaticAbsorption(toward: parent.position)
        }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        // SpriteKit can briefly resize a newly attached `.resizeFill` scene to
        // zero before Auto Layout supplies the popover's real bounds. Clamping
        // during that transient size would collapse every actor into one
        // corner and permanently discard its deterministic starting position.
        guard
            size.width >= Self.actorBoundaryMargin * 2,
            size.height >= Self.actorBoundaryMargin * 2
        else { return }
        actorNodes.values.forEach { $0.position = bounded($0.position) }
        relayoutPresentedCompletionReceipts()
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
            reduceMotion: reduceMotion,
            increaseContrast: increaseContrast
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
            node.updateStateMarkerRotation()
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
        case .wait, .finished, .ripple, .cancelled, .failed: 0
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
        let familyId = familyRootActorId(for: intent)
        let seed = stableSeed(familyId)
        let baseColor = identityPalette[identitySlot(seed: seed)]
        let depth = familyDepth(for: intent)
        guard
            depth > 0,
            let components = baseColor.usingColorSpace(.sRGB)
        else { return baseColor }

        // Descendants inherit the exact family hue. A small luminance step,
        // together with their smaller body, keeps parent and child legible.
        let multiplier = max(0.68, 0.88 - CGFloat(depth - 1) * 0.06)
        return NSColor(
            srgbRed: components.redComponent * multiplier,
            green: components.greenComponent * multiplier,
            blue: components.blueComponent * multiplier,
            alpha: 1
        )
    }

    private func completionReceiptSnapshot(
        for actorId: String,
        kind: CompletionReceiptKind
    ) -> CompletionReceipt {
        if let intent = intentsById[actorId] {
            return CompletionReceipt(
                actorId: actorId,
                kind: kind,
                color: color(for: intent),
                position: bounded(actorNodes[actorId]?.position ?? randomPoint(seed: intent.seed))
            )
        }

        let seed = stableSeed(actorId)
        let color = identityPalette[Int(seed % UInt64(identityPalette.count))]
        return CompletionReceipt(
            actorId: actorId,
            kind: kind,
            color: color,
            position: bounded(randomPoint(seed: seed))
        )
    }

    private func showWorkEndRipple(for actor: TadpoleNode) {
        guard !reduceMotion else { return }
        let ring = SKShapeNode(circleOfRadius: actor.workEndRippleRadius)
        ring.name = Self.workEndRippleNodeName
        ring.position = actor.position
        ring.zPosition = 12
        ring.fillColor = .clear
        ring.userData = NSMutableDictionary()
        ring.userData?[Self.workEndRippleColorKey] = actor.workEndRippleColor
        updateWorkEndRippleAppearance(ring)
        addChild(ring)
        ring.run(.sequence([
            .group([
                .scale(to: 4.2, duration: 2.8),
                .fadeOut(withDuration: 2.8),
            ]),
            .removeFromParent(),
        ]))
    }

    private func updateWorkEndRippleAppearance(_ node: SKNode) {
        guard
            let ring = node as? SKShapeNode,
            let color = ring.userData?[Self.workEndRippleColorKey] as? NSColor
        else { return }
        ring.strokeColor = color.withAlphaComponent(increaseContrast ? 0.90 : 0.52)
        ring.lineWidth = increaseContrast ? 1.4 : 1
    }

    private var presentedWorkEndRippleNodes: [SKNode] {
        children.filter { $0.name == Self.workEndRippleNodeName }
    }

    private func addCompletionReceiptNode(_ receipt: CompletionReceipt, at position: CGPoint) {
        let container = SKNode()
        container.name = Self.completionReceiptNodeName
        container.position = position
        container.zPosition = 20
        container.userData = NSMutableDictionary()
        container.userData?[Self.completionReceiptColorKey] = receipt.color

        let ghost = SKShapeNode(circleOfRadius: 5.4)
        ghost.name = Self.completionReceiptGhostNodeName
        container.addChild(ghost)

        switch receipt.kind {
        case .finished:
            let arc = SKShapeNode(path: completionArcPath(radius: 10.5))
            arc.name = Self.completionReceiptFinishedNodeName
            arc.lineCap = .round
            container.addChild(arc)
        case .completed:
            for radius in [9.0, 12.5] as [CGFloat] {
                let halo = SKShapeNode(circleOfRadius: radius)
                halo.name = radius < 10
                    ? Self.completionReceiptInnerHaloNodeName
                    : Self.completionReceiptOuterHaloNodeName
                container.addChild(halo)
            }
        }

        addChild(container)
        updateCompletionReceiptAppearance(container)
        runCompletionReceiptPresentation(container)
    }

    private func runCompletionReceiptPresentation(_ container: SKNode) {
        container.removeAllActions()
        if reduceMotion {
            container.alpha = 1
            container.setScale(1)
            container.run(.sequence([
                .wait(forDuration: 2.4),
                .removeFromParent(),
            ]))
        } else {
            container.alpha = 0
            container.setScale(0.76)
            container.run(.sequence([
                .group([
                    .fadeIn(withDuration: 0.16),
                    .scale(to: 1.08, duration: 0.32),
                ]),
                .scale(to: 1, duration: 0.18),
                .wait(forDuration: 1.55),
                .group([
                    .fadeOut(withDuration: 0.45),
                    .scale(to: 1.18, duration: 0.45),
                ]),
                .removeFromParent(),
            ]))
        }
    }

    private func settleCompletionReceiptForReduceMotion(_ container: SKNode) {
        container.removeAllActions()
        container.alpha = 1
        container.setScale(1)
        container.run(.sequence([
            .wait(forDuration: 2.4),
            .removeFromParent(),
        ]))
    }

    private func updateCompletionReceiptAppearance(_ container: SKNode) {
        guard
            let color = container.userData?[Self.completionReceiptColorKey] as? NSColor
        else { return }

        if let ghost = container.childNode(
            withName: Self.completionReceiptGhostNodeName
        ) as? SKShapeNode {
            ghost.fillColor = color.withAlphaComponent(increaseContrast ? 0.56 : 0.30)
            ghost.strokeColor = NSColor.white.withAlphaComponent(increaseContrast ? 0.96 : 0.68)
            ghost.lineWidth = increaseContrast ? 1.8 : 1.0
        }
        if let arc = container.childNode(
            withName: Self.completionReceiptFinishedNodeName
        ) as? SKShapeNode {
            arc.fillColor = .clear
            arc.strokeColor = color.withAlphaComponent(increaseContrast ? 1 : 0.86)
            arc.lineWidth = increaseContrast ? 2.4 : 1.5
        }
        if let innerHalo = container.childNode(
            withName: Self.completionReceiptInnerHaloNodeName
        ) as? SKShapeNode {
            innerHalo.fillColor = .clear
            innerHalo.strokeColor = color.withAlphaComponent(increaseContrast ? 1 : 0.92)
            innerHalo.lineWidth = increaseContrast ? 2.0 : 1.25
        }
        if let outerHalo = container.childNode(
            withName: Self.completionReceiptOuterHaloNodeName
        ) as? SKShapeNode {
            outerHalo.fillColor = .clear
            outerHalo.strokeColor = color.withAlphaComponent(increaseContrast ? 1 : 0.64)
            outerHalo.lineWidth = increaseContrast ? 2.0 : 1.25
        }
    }

    private func completionArcPath(radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addArc(
            center: .zero,
            radius: radius,
            startAngle: -.pi * 0.70,
            endAngle: .pi * 0.82,
            clockwise: false
        )
        return path
    }

    private func removePresentedCompletionReceipts() {
        presentedCompletionReceiptNodes.forEach { $0.removeFromParent() }
    }

    private var presentedCompletionReceiptNodes: [SKNode] {
        children.filter { $0.name == Self.completionReceiptNodeName }
    }

    private func relayoutPresentedCompletionReceipts() {
        var occupiedPositions: [CGPoint] = []
        for node in presentedCompletionReceiptNodes {
            let position = resolvedCompletionReceiptPosition(
                preferred: node.position,
                occupied: occupiedPositions
            )
            node.position = position
            occupiedPositions.append(position)
        }
    }

    private func resolvedCompletionReceiptPosition(
        preferred: CGPoint,
        occupied: [CGPoint]
    ) -> CGPoint {
        let preferred = boundedCompletionReceipt(preferred)
        let radii: [CGFloat] = [0, 38, 54, 76, 96]
        for radius in radii {
            let stepCount = radius == 0 ? 1 : 12
            for step in 0..<stepCount {
                let angle = CGFloat(step) / CGFloat(stepCount) * .pi * 2
                let candidate = boundedCompletionReceipt(CGPoint(
                    x: preferred.x + cos(angle) * radius,
                    y: preferred.y + sin(angle) * radius
                ))
                let clearsExistingReceipts = occupied.allSatisfy {
                    receiptDistance(candidate, $0)
                        >= Self.completionReceiptMinimumSeparation
                }
                if clearsExistingReceipts {
                    return candidate
                }
            }
        }
        return preferred
    }

    private func boundedCompletionReceipt(_ point: CGPoint) -> CGPoint {
        let margin = Self.completionReceiptBoundaryMargin
        return CGPoint(
            x: min(max(margin, point.x), max(margin, size.width - margin)),
            y: min(max(margin, point.y), max(margin, size.height - margin))
        )
    }

    private func receiptDistance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }

    private func removeMissingNodes(validIds: Set<String>) {
        actorNodes.keys.filter { !validIds.contains($0) }.forEach { id in
            actorNodes.removeValue(forKey: id)?.removeFromParent()
        }
    }

    private func identitySlot(seed: UInt64) -> Int {
        // Family identity must not depend on which other families happen to be
        // live. The reducer's stable seed therefore maps directly to a palette
        // slot, and the same mapping can be reconstructed for an unseen receipt.
        return Int(seed % UInt64(identityPalette.count))
    }

    private func familyRootActorId(for intent: WorldIntent) -> String {
        var rootId = intent.actorId
        var parentId = intent.parentActorId
        var visited = Set([intent.actorId])
        while let candidateId = parentId, visited.insert(candidateId).inserted {
            rootId = candidateId
            parentId = intentsById[candidateId]?.parentActorId
        }
        return rootId
    }

    private func familyDepth(for intent: WorldIntent) -> Int {
        var depth = 0
        var parentId = intent.parentActorId
        var visited = Set([intent.actorId])
        while let candidateId = parentId, visited.insert(candidateId).inserted {
            depth += 1
            parentId = intentsById[candidateId]?.parentActorId
        }
        return depth
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
        if reduceMotion {
            fieldEnergy = targetFieldEnergy
        } else {
            let blend = min(1, CGFloat(delta) * 0.5)
            fieldEnergy += (targetFieldEnergy - fieldEnergy) * blend
        }
        backgroundColor = NSColor(
            srgbRed: 0.018 + fieldEnergy * 0.010,
            green: 0.026 + fieldEnergy * 0.014,
            blue: 0.055 + fieldEnergy * 0.018,
            alpha: 1
        )
    }

    private func showWorkEndBreath() {
        childNode(withName: "work-end-breath")?.removeFromParent()
        let breath = SKShapeNode(circleOfRadius: min(size.width, size.height) * 0.12)
        breath.name = "work-end-breath"
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
        let margin = Self.actorBoundaryMargin
        return CGPoint(
            x: min(max(margin, point.x), max(margin, size.width - margin)),
            y: min(max(margin, point.y), max(margin, size.height - margin))
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
