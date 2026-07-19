import AgentMeongCore
import AppKit
import SpriteKit

@MainActor
final class TadpoleNode: SKNode {
    private static let stateEffectNodeName = "state-effect"
    private static let activeChevronNodeName = "active-chevron"
    private static let toolImpulseNodePrefix = "tool-impulse-"
    private static let maximumToolImpulseCount = 3
    private static let familyReceiptActionKey = "family-receipt"

    let motionPhase: CGFloat
    let speedFactor: CGFloat
    var velocity = CGVector.zero
    private(set) var isAbsorbing = false

    private let radius: CGFloat
    private let head: SKShapeNode
    private let tail: SKShapeNode
    private let restingTailBend: CGFloat
    private var currentTailBend: CGFloat
    private var stateColor: NSColor
    private var currentVisualState: VisualState?
    private var currentMotion: MotionMode?
    private var currentReduceMotion = false
    private var currentIncreaseContrast = false
    private var absorptionProgress: CGFloat = 0
    private var stateMarkerContainer: SKNode?
    private var toolImpulseSequence = 0

    var toolImpulseCountForE2E: Int {
        children.filter {
            $0.name?.hasPrefix(Self.toolImpulseNodePrefix) == true
        }.count
    }

    var isActiveTailLegibleForE2E: Bool {
        guard currentMotion == .flow else { return true }
        return tail.path != nil
            && tail.lineWidth >= 1.5
            && tail.alpha >= 0.58
            && tail.strokeColor.alphaComponent >= 0.98
    }

    func usesStateColorForE2E(_ expected: NSColor) -> Bool {
        head.fillColor.isEqual(expected)
            && tail.strokeColor.isEqual(expected)
    }

    init(
        radius: CGFloat,
        state: VisualState,
        tailBend: CGFloat,
        motionPhase: CGFloat,
        speedFactor: CGFloat
    ) {
        self.radius = radius
        stateColor = AgentMeongPalette.statusColor(for: state)
        self.motionPhase = motionPhase
        self.speedFactor = speedFactor
        restingTailBend = tailBend
        currentTailBend = tailBend
        head = SKShapeNode(circleOfRadius: radius)
        tail = SKShapeNode(path: Self.tailPath(radius: radius, bend: tailBend))
        super.init()
        configureNodes()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        state: VisualState,
        motion: MotionMode,
        reduceMotion: Bool,
        increaseContrast: Bool
    ) {
        updateStateColor(
            AgentMeongPalette.statusColor(for: state),
            increaseContrast: increaseContrast
        )
        guard
            currentVisualState != state
                || currentMotion != motion
                || currentReduceMotion != reduceMotion
                || currentIncreaseContrast != increaseContrast
        else { return }
        currentVisualState = state
        currentMotion = motion
        currentReduceMotion = reduceMotion
        currentIncreaseContrast = increaseContrast
        resetAppearance()

        let presentation = StatePresentation.make(
            for: state,
            increaseContrast: increaseContrast
        )
        alpha = presentation.bodyAlpha
        tail.alpha = presentation.tailAlpha
        if
            let marker = presentation.marker,
            let accentColor = presentation.accentColor
        {
            showStateMarker(
                marker,
                color: accentColor,
                maximumAlpha: presentation.markerAlpha,
                pulseDuration: presentation.pulseDuration,
                animate: !reduceMotion,
                increaseContrast: increaseContrast
            )
        } else if state == .active, reduceMotion {
            showStateMarker(
                .activeTick,
                color: NSColor.white,
                maximumAlpha: increaseContrast ? 1 : 0.82,
                pulseDuration: nil,
                animate: false,
                increaseContrast: increaseContrast
            )
        }
        if let duration = presentation.breatheDuration, !reduceMotion {
            breathe(duration: duration)
        }
    }

    var workEndRippleColor: NSColor {
        let presentation = StatePresentation.make(
            for: currentVisualState ?? .finished,
            increaseContrast: currentIncreaseContrast
        )
        return presentation.accentColor ?? stateColor
    }

    var workEndRippleRadius: CGFloat { radius + 2 }

    /// Verifies the rendered SpriteKit nodes without exposing actor identity or
    /// any observed payload in E2E output.
    var hasStaticActiveChevronForE2E: Bool {
        guard
            currentMotion == .flow,
            currentReduceMotion,
            let container = stateMarkerContainer,
            container.name == Self.stateEffectNodeName,
            !container.hasActions(),
            let chevron = container.childNode(
                withName: Self.activeChevronNodeName
            ) as? SKShapeNode
        else { return false }
        return chevron.path != nil && !chevron.hasActions()
    }

    func updateStateMarkerRotation() {
        stateMarkerContainer?.zRotation = -zRotation
    }

    /// A short, decorative response to a privacy-safe tool category. It never
    /// becomes durable state and is suppressed to a static blink when Reduce
    /// Motion is enabled.
    func showToolImpulse(
        category _: ToolCategory?,
        started: Bool,
        reduceMotion: Bool,
        increaseContrast: Bool
    ) {
        let existingImpulses = children.filter {
            $0.name?.hasPrefix(Self.toolImpulseNodePrefix) == true
        }
        if existingImpulses.count >= Self.maximumToolImpulseCount {
            existingImpulses.first?.removeFromParent()
        }
        // Placement is decorative. Tool category never gains a hidden spatial
        // grammar; only filled/outward versus hollow/inward distinguishes the
        // observed start and finish lifecycle events.
        let angle = decorativeToolImpulseAngle()
        let direction = CGVector(dx: cos(angle), dy: sin(angle))
        let rotatedDirection = AmbientMotionProfile.rotatedDirection(
            localAngle: Double(angle),
            nodeRotation: Double(zRotation)
        )
        let worldDirection = CGVector(
            dx: CGFloat(rotatedDirection.dx),
            dy: CGFloat(rotatedDirection.dy)
        )
        let radius = increaseContrast ? 2.2 : (started ? 2.0 : 1.8)
        let dot = SKShapeNode(circleOfRadius: radius)
        toolImpulseSequence = (toolImpulseSequence + 1) % 10_000
        dot.name = "\(Self.toolImpulseNodePrefix)\(toolImpulseSequence)"
        dot.fillColor = started ? stateColor : .clear
        dot.strokeColor = increaseContrast ? NSColor.white : stateColor
        dot.lineWidth = increaseContrast ? 0.8 : (started ? 0 : 0.9)
        dot.position = CGPoint(
            x: direction.dx * (self.radius + 5),
            y: direction.dy * (self.radius + 5)
        )
        dot.zPosition = 3
        addChild(dot)

        guard !reduceMotion else {
            dot.run(.sequence([.wait(forDuration: 0.48), .removeFromParent()]))
            return
        }

        let distance: CGFloat = started ? 11 : -6
        velocity.dx += worldDirection.dx * (started ? 5.6 : -2)
        velocity.dy += worldDirection.dy * (started ? 5.6 : -2)
        dot.run(.sequence([
            .group([
                .move(by: CGVector(dx: direction.dx * distance, dy: direction.dy * distance), duration: 0.46),
                .fadeOut(withDuration: 0.46),
                .scale(to: started ? 1.42 : 0.68, duration: 0.46),
            ]),
            .removeFromParent(),
        ]))
    }

    func showBirth(reduceMotion: Bool) {
        guard !reduceMotion else { return }
        removeAction(forKey: "birth")
        setScale(0.16)
        alpha = 0.12
        let appear = SKAction.group([
            .scale(to: 1, duration: 0.46),
            .fadeAlpha(to: 1, duration: 0.34),
        ])
        appear.timingMode = .easeOut
        run(appear, withKey: "birth")
    }

    func beginAbsorption() {
        isAbsorbing = true
        absorptionProgress = 0
        alpha = 1
        setScale(1)
    }

    func showStaticAbsorption(toward target: CGPoint) {
        isAbsorbing = false
        absorptionProgress = 1
        position = target
        setScale(0.18)
        alpha = 0.08
    }

    func updateAbsorption(toward target: CGPoint, delta: TimeInterval) {
        guard isAbsorbing else { return }
        absorptionProgress = min(1, absorptionProgress + CGFloat(delta) / 0.84)
        let positionBlend = min(1, CGFloat(delta) * 5.5)
        position = CGPoint(
            x: position.x + (target.x - position.x) * positionBlend,
            y: position.y + (target.y - position.y) * positionBlend
        )
        let eased = 1 - pow(1 - absorptionProgress, 2)
        setScale(max(0.18, 1 - eased * 0.82))
        alpha = max(0.08, 1 - eased * 0.92)
        if absorptionProgress >= 1 {
            position = target
            isAbsorbing = false
        }
    }

    func showAbsorptionReceipt(reduceMotion: Bool) {
        guard !reduceMotion else { return }
        let receipt = SKAction.sequence([
            .scale(to: 1.16, duration: 0.14),
            .scale(to: 1, duration: 0.30),
        ])
        receipt.timingMode = .easeInEaseOut
        run(receipt, withKey: Self.familyReceiptActionKey)
    }

    func showBirthReceipt(reduceMotion: Bool) {
        guard !reduceMotion else { return }
        let receipt = SKAction.sequence([
            .scale(to: 0.92, duration: 0.12),
            .scale(to: 1.08, duration: 0.14),
            .scale(to: 1, duration: 0.20),
        ])
        receipt.timingMode = .easeInEaseOut
        run(receipt, withKey: Self.familyReceiptActionKey)
    }

    func discardTransientPresentation() {
        children.filter {
            $0.name?.hasPrefix(Self.toolImpulseNodePrefix) == true
        }.forEach { $0.removeFromParent() }
        removeAction(forKey: "birth")
        removeAction(forKey: Self.familyReceiptActionKey)
        guard !isAbsorbing else { return }
        setScale(1)
        if let currentVisualState {
            alpha = StatePresentation.make(
                for: currentVisualState,
                increaseContrast: currentIncreaseContrast
            ).bodyAlpha
        }
    }

    func updateTail(at time: CGFloat, lateralAcceleration: CGFloat, reduceMotion: Bool) {
        guard !reduceMotion else { return }
        let wave = sin(time * 2.45 + motionPhase) * radius * 0.70
        let target = restingTailBend + wave - lateralAcceleration * radius * 0.04
        currentTailBend += (target - currentTailBend) * 0.12
        tail.path = Self.tailPath(radius: radius, bend: currentTailBend)
    }

    private func configureNodes() {
        tail.lineWidth = max(1.55, radius * 0.34)
        tail.lineCap = .round
        tail.zPosition = -1
        addChild(tail)

        head.glowWidth = radius * 0.72
        addChild(head)
        updateStateColor(stateColor, increaseContrast: false)
    }

    private func updateStateColor(_ nextColor: NSColor, increaseContrast: Bool) {
        stateColor = nextColor
        // StatePresentation owns tail opacity. Keeping the stroke itself opaque
        // avoids multiplying two low alpha values into a hairline appearance.
        tail.strokeColor = stateColor
        head.fillColor = stateColor
        head.strokeColor = increaseContrast
            ? NSColor.white.withAlphaComponent(0.94)
            : stateColor.withAlphaComponent(0.22)
        head.lineWidth = increaseContrast ? max(1.1, radius * 0.28) : 1
        head.glowWidth = radius * (increaseContrast ? 0.28 : 0.72)
    }

    private func resetAppearance() {
        removeAllActions()
        stateMarkerContainer?.removeFromParent()
        stateMarkerContainer = nil
        children.filter {
            $0.name?.hasPrefix(Self.toolImpulseNodePrefix) == true
        }.forEach { $0.removeFromParent() }
        head.removeAllActions()
        tail.removeAllActions()
        head.setScale(1)
        setScale(1)
        alpha = 1
        isAbsorbing = false
        absorptionProgress = 0
    }

    private func breathe(duration: TimeInterval) {
        let action = SKAction.sequence([
            .scale(to: 1.07, duration: duration),
            .scale(to: 0.96, duration: duration),
        ])
        action.timingMode = .easeInEaseOut
        head.run(.repeatForever(action), withKey: "breathing")
    }

    private func showStateMarker(
        _ marker: StateMarkerKind,
        color: NSColor,
        maximumAlpha: CGFloat,
        pulseDuration: TimeInterval?,
        animate: Bool,
        increaseContrast: Bool
    ) {
        let container = SKNode()
        container.name = Self.stateEffectNodeName
        container.alpha = maximumAlpha
        container.zPosition = 2
        container.zRotation = -zRotation
        let lineWidth: CGFloat = increaseContrast ? 1.55 : 0.9

        func styledShape(path: CGPath) -> SKShapeNode {
            let shape = SKShapeNode(path: path)
            shape.strokeColor = color
            shape.fillColor = .clear
            shape.lineWidth = lineWidth
            shape.lineCap = .round
            return shape
        }

        switch marker {
        case .activeTick:
            let path = CGMutablePath()
            let inner = radius + 4
            let outer = radius + 9
            path.move(to: CGPoint(x: inner, y: -4))
            path.addLine(to: CGPoint(x: outer, y: 0))
            path.addLine(to: CGPoint(x: inner, y: 4))
            let tick = styledShape(path: path)
            tick.name = Self.activeChevronNodeName
            tick.lineWidth = increaseContrast ? 2.2 : 1.4
            container.addChild(tick)
        case .approvalRing:
            let ring = SKShapeNode(circleOfRadius: radius + 9)
            ring.strokeColor = color
            ring.fillColor = .clear
            ring.lineWidth = lineWidth
            container.addChild(ring)
        case .uncertainSegments:
            let path = CGMutablePath()
            let segmentRadius = radius + 8
            for index in 0..<6 {
                let start = CGFloat(index) * .pi / 3 + 0.10
                path.addArc(
                    center: .zero,
                    radius: segmentRadius,
                    startAngle: start,
                    endAngle: start + 0.68,
                    clockwise: false
                )
            }
            container.addChild(styledShape(path: path))
        case .finishedArc:
            let path = CGMutablePath()
            path.addArc(
                center: .zero,
                radius: radius + 7,
                startAngle: .pi * 0.15,
                endAngle: .pi * 1.72,
                clockwise: false
            )
            container.addChild(styledShape(path: path))
        case .completedHalo:
            for offset in [CGFloat(5), CGFloat(9)] {
                let ring = SKShapeNode(circleOfRadius: radius + offset)
                ring.strokeColor = color
                ring.fillColor = .clear
                ring.lineWidth = lineWidth
                container.addChild(ring)
            }
        case .cancelledBar:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -radius - 6, y: 0))
            path.addLine(to: CGPoint(x: radius + 6, y: 0))
            let bar = styledShape(path: path)
            bar.lineWidth = increaseContrast ? 2.4 : 1.6
            container.addChild(bar)
        case .failedDiamond:
            let markerRadius = radius + 7
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: markerRadius))
            path.addLine(to: CGPoint(x: markerRadius, y: 0))
            path.addLine(to: CGPoint(x: 0, y: -markerRadius))
            path.addLine(to: CGPoint(x: -markerRadius, y: 0))
            path.closeSubpath()
            container.addChild(styledShape(path: path))
        }

        addChild(container)
        stateMarkerContainer = container
        if animate, let pulseDuration {
            container.run(.repeatForever(.sequence([
                .fadeAlpha(to: max(0.24, maximumAlpha * 0.42), duration: pulseDuration),
                .fadeAlpha(to: maximumAlpha, duration: pulseDuration),
            ])))
        }
    }

    private func decorativeToolImpulseAngle() -> CGFloat {
        let slot = CGFloat((toolImpulseSequence * 3 + 1) % 10)
        return motionPhase + slot * (.pi * 2 / 10)
    }

    private static func tailPath(radius: CGFloat, bend: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -radius * 0.8, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: -radius * 4.6, y: bend),
            control: CGPoint(x: -radius * 2.6, y: -bend)
        )
        return path
    }
}
