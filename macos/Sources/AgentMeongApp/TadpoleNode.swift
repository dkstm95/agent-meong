import AgentMeongCore
import AppKit
import SpriteKit

@MainActor
final class TadpoleNode: SKNode {
    let motionPhase: CGFloat
    let speedFactor: CGFloat
    var velocity = CGVector.zero
    private(set) var isAbsorbing = false

    private let radius: CGFloat
    private let head: SKShapeNode
    private let tail: SKShapeNode
    private let restingTailBend: CGFloat
    private var currentTailBend: CGFloat
    private var color: NSColor
    private var currentMotion: MotionMode?
    private var currentReduceMotion = false
    private var currentIncreaseContrast = false
    private var absorptionProgress: CGFloat = 0

    init(
        radius: CGFloat,
        color: NSColor,
        tailBend: CGFloat,
        motionPhase: CGFloat,
        speedFactor: CGFloat
    ) {
        self.radius = radius
        self.color = color
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
        _ motion: MotionMode,
        color: NSColor,
        reduceMotion: Bool,
        increaseContrast: Bool
    ) {
        updateColor(color, increaseContrast: increaseContrast)
        guard
            currentMotion != motion
                || currentReduceMotion != reduceMotion
                || currentIncreaseContrast != increaseContrast
        else { return }
        currentMotion = motion
        currentReduceMotion = reduceMotion
        currentIncreaseContrast = increaseContrast
        resetAppearance()

        switch motion {
        case .drift:
            tail.alpha = increaseContrast ? 0.32 : 0.16
            alpha = increaseContrast ? 0.88 : 0.62
            if !reduceMotion { breathe(duration: 2.8) }
        case .flow:
            tail.alpha = increaseContrast ? 0.68 : 0.48
            if !reduceMotion { breathe(duration: 1.8) }
        case .wait:
            tail.alpha = increaseContrast ? 0.24 : 0.08
            showRing(
                radius: radius + 9,
                duration: 1.4,
                maximumAlpha: increaseContrast ? 0.88 : 0.68,
                animate: !reduceMotion
            )
        case .uncertain:
            tail.alpha = increaseContrast ? 0.20 : 0.05
            alpha = increaseContrast ? 0.82 : 0.48
            showRing(
                radius: radius + 7,
                duration: 3.2,
                maximumAlpha: increaseContrast ? 0.68 : 0.28,
                animate: !reduceMotion
            )
        case .finished:
            tail.alpha = increaseContrast ? 0.18 : 0.04
            showWorkEndRipple(animate: !reduceMotion)
        case .ripple:
            tail.alpha = increaseContrast ? 0.18 : 0.04
            showWorkEndRipple(animate: !reduceMotion)
        case .cancelled:
            tail.alpha = increaseContrast ? 0.16 : 0.03
            alpha = increaseContrast ? 0.82 : 0.46
            showRing(
                radius: radius + 5,
                duration: 3,
                maximumAlpha: increaseContrast ? 0.62 : 0.22,
                animate: !reduceMotion
            )
        case .failed:
            tail.alpha = increaseContrast ? 0.22 : 0.05
            showRing(
                radius: radius + 9,
                duration: 2.1,
                maximumAlpha: increaseContrast ? 0.86 : 0.52,
                animate: !reduceMotion
            )
        }
    }

    func showBirth(reduceMotion: Bool) {
        guard !reduceMotion else { return }
        removeAction(forKey: "birth")
        setScale(0.20)
        alpha = 0.12
        let appear = SKAction.group([
            .scale(to: 1, duration: 0.56),
            .fadeAlpha(to: 1, duration: 0.38),
        ])
        appear.timingMode = .easeOut
        run(appear, withKey: "birth")
    }

    func beginAbsorption() {
        removeAction(forKey: "completion-settle")
        isAbsorbing = true
        absorptionProgress = 0
        alpha = 1
        setScale(1)
    }

    func showStaticAbsorption(toward target: CGPoint) {
        removeAction(forKey: "completion-settle")
        isAbsorbing = false
        absorptionProgress = 1
        position = target
        setScale(0.18)
        alpha = 0.08
    }

    func updateAbsorption(toward target: CGPoint, delta: TimeInterval) {
        guard isAbsorbing else { return }
        absorptionProgress = min(1, absorptionProgress + CGFloat(delta) / 1.05)
        let positionBlend = min(1, CGFloat(delta) * 4.2)
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
            .scale(to: 1.13, duration: 0.16),
            .scale(to: 1, duration: 0.34),
        ])
        receipt.timingMode = .easeInEaseOut
        run(receipt, withKey: "absorption-receipt")
    }

    func updateTail(at time: CGFloat, lateralAcceleration: CGFloat, reduceMotion: Bool) {
        guard !reduceMotion else { return }
        let wave = sin(time * 2.1 + motionPhase) * radius * 0.62
        let target = restingTailBend + wave - lateralAcceleration * radius * 0.04
        currentTailBend += (target - currentTailBend) * 0.12
        tail.path = Self.tailPath(radius: radius, bend: currentTailBend)
    }

    private func configureNodes() {
        tail.lineWidth = max(0.8, radius * 0.23)
        tail.lineCap = .round
        tail.zPosition = -1
        addChild(tail)

        head.glowWidth = radius * 0.72
        addChild(head)
        updateColor(color, increaseContrast: false)
    }

    private func updateColor(_ nextColor: NSColor, increaseContrast: Bool) {
        color = nextColor
        tail.strokeColor = color.withAlphaComponent(increaseContrast ? 0.72 : 0.34)
        head.fillColor = color
        head.strokeColor = increaseContrast
            ? NSColor.white.withAlphaComponent(0.94)
            : color.withAlphaComponent(0.22)
        head.lineWidth = increaseContrast ? max(1.1, radius * 0.28) : 1
        head.glowWidth = radius * (increaseContrast ? 0.28 : 0.72)
    }

    private func resetAppearance() {
        removeAllActions()
        childNode(withName: "state-effect")?.removeFromParent()
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

    private func showRing(
        radius: CGFloat,
        duration: TimeInterval,
        maximumAlpha: CGFloat = 0.68,
        animate: Bool
    ) {
        let ring = SKShapeNode(circleOfRadius: radius)
        ring.name = "state-effect"
        ring.strokeColor = color.withAlphaComponent(maximumAlpha)
        ring.lineWidth = 0.8
        ring.fillColor = .clear
        addChild(ring)
        if animate {
            ring.run(.repeatForever(.sequence([
                .fadeAlpha(to: 0.16, duration: duration),
                .fadeAlpha(to: maximumAlpha, duration: duration),
            ])))
        }
    }

    private func showWorkEndRipple(animate: Bool) {
        let ring = SKShapeNode(circleOfRadius: radius + 2)
        ring.name = "state-effect"
        ring.strokeColor = color.withAlphaComponent(currentIncreaseContrast ? 0.90 : 0.52)
        ring.lineWidth = currentIncreaseContrast ? 1.4 : 1
        ring.fillColor = .clear
        addChild(ring)
        guard animate else { return }
        ring.run(.sequence([
            .group([
                .scale(to: 4.2, duration: 2.8),
                .fadeOut(withDuration: 2.8),
            ]),
            .removeFromParent(),
        ]))
        run(.group([
            .fadeAlpha(to: 0.24, duration: 6.5),
            .scale(to: 0.82, duration: 6.5),
        ]), withKey: "completion-settle")
    }

    private static func tailPath(radius: CGFloat, bend: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -radius * 0.8, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: -radius * 5.4, y: bend),
            control: CGPoint(x: -radius * 3, y: -bend)
        )
        return path
    }
}
