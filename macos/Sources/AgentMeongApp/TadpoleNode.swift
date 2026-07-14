import AgentMeongCore
import AppKit
import SpriteKit

@MainActor
final class TadpoleNode: SKNode {
    let motionPhase: CGFloat
    let speedFactor: CGFloat
    var velocity = CGVector.zero

    private let radius: CGFloat
    private let head: SKShapeNode
    private let tail: SKShapeNode
    private let restingTailBend: CGFloat
    private var currentTailBend: CGFloat
    private var color: NSColor
    private var currentMotion: MotionMode?
    private var currentReduceMotion = false

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

    func apply(_ motion: MotionMode, color: NSColor, reduceMotion: Bool) {
        updateColor(color)
        guard currentMotion != motion || currentReduceMotion != reduceMotion else { return }
        currentMotion = motion
        currentReduceMotion = reduceMotion
        resetAppearance()

        switch motion {
        case .drift:
            tail.alpha = 0.16
            alpha = 0.62
            if !reduceMotion { breathe(duration: 2.8) }
        case .flow:
            tail.alpha = 0.48
            if !reduceMotion { breathe(duration: 1.8) }
        case .wait:
            tail.alpha = 0.08
            showRing(radius: radius + 9, duration: 1.4, animate: !reduceMotion)
        case .uncertain:
            tail.alpha = 0.05
            alpha = 0.48
            showRing(
                radius: radius + 7,
                duration: 3.2,
                maximumAlpha: 0.28,
                animate: !reduceMotion
            )
        case .ripple:
            tail.alpha = 0.04
            showCompletionRipple(animate: !reduceMotion)
        case .failed:
            tail.alpha = 0.05
            showRing(
                radius: radius + 9,
                duration: 2.1,
                maximumAlpha: 0.52,
                animate: !reduceMotion
            )
        }
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
        updateColor(color)
    }

    private func updateColor(_ nextColor: NSColor) {
        color = nextColor
        tail.strokeColor = color.withAlphaComponent(0.34)
        head.fillColor = color
        head.strokeColor = color.withAlphaComponent(0.22)
    }

    private func resetAppearance() {
        removeAllActions()
        childNode(withName: "state-effect")?.removeFromParent()
        head.removeAllActions()
        tail.removeAllActions()
        head.setScale(1)
        setScale(1)
        alpha = 1
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

    private func showCompletionRipple(animate: Bool) {
        let ring = SKShapeNode(circleOfRadius: radius + 2)
        ring.name = "state-effect"
        ring.strokeColor = color.withAlphaComponent(0.52)
        ring.lineWidth = 1
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
        ]))
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
