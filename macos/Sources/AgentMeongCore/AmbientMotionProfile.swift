import Foundation

public struct AmbientMotionVector: Equatable, Sendable {
    public let dx: Double
    public let dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
}

/// Deterministic presentation tuning for the ambient scene. These values never
/// change observed state; they only turn a `MotionMode` into decorative motion.
public enum AmbientMotionProfile {
    public static let boundaryMargin = 64.0

    public static func baseSpeed(for motion: MotionMode) -> Double {
        switch motion {
        case .drift: 9
        case .flow: 34
        case .uncertain: 3
        case .wait, .finished, .ripple, .cancelled, .failed: 0
        }
    }

    public static func speedMultiplier(time: Double, phase: Double) -> Double {
        max(
            0.68,
            0.86
                + 0.10 * sin(time * 0.31 + phase)
                + 0.04 * sin(time * 0.73 + phase * 1.43)
        )
    }

    public static func steeringBlend(delta: Double) -> Double {
        min(1, max(0, delta) * 2.2)
    }

    public static func separationStrength(distance: Double) -> Double {
        guard distance > 0, distance < 34 else { return 0 }
        return (34 - distance) / 8
    }

    public static func boundaryStrength(distanceToEdge: Double) -> Double {
        guard distanceToEdge < boundaryMargin else { return 0 }
        return (boundaryMargin - distanceToEdge) / 12
    }

    /// Positive radial values pull a child toward its parent; negative values
    /// push it away. Tangential motion makes the relationship legible without
    /// implying any additional agent event.
    public static func familySteering(
        distance: Double,
        clockwise: Bool
    ) -> (radial: Double, tangential: Double) {
        let radial: Double
        if distance > 58 {
            radial = min(3, (distance - 58) / 20)
        } else if distance < 40 {
            radial = -min(2.4, (40 - distance) / 10)
        } else {
            radial = 0
        }

        let tangentialMagnitude: Double
        if distance <= 32 || distance >= 82 {
            tangentialMagnitude = 0
        } else {
            let entering = min(1, (distance - 32) / 10)
            let leaving = min(1, (82 - distance) / 16)
            tangentialMagnitude = 0.72 * max(0, min(entering, leaving))
        }
        return (radial, clockwise ? -tangentialMagnitude : tangentialMagnitude)
    }

    public static func encounterTangentialStrength(
        distance: Double,
        clockwise: Bool
    ) -> Double {
        guard distance >= 34, distance < 72 else { return 0 }
        let entering = min(1, max(0, (distance - 34) / 8))
        let leaving = min(1, max(0, (72 - distance) / 18))
        let magnitude = 0.42 * min(entering, leaving)
        return clockwise ? -magnitude : magnitude
    }

    public static func rotatedDirection(
        localAngle: Double,
        nodeRotation: Double
    ) -> AmbientMotionVector {
        let worldAngle = localAngle + nodeRotation
        return AmbientMotionVector(dx: cos(worldAngle), dy: sin(worldAngle))
    }

    public static func separationVector(
        offsetX: Double,
        offsetY: Double
    ) -> AmbientMotionVector {
        let distance = hypot(offsetX, offsetY)
        let strength = separationStrength(distance: distance)
        guard distance > 0, strength > 0 else {
            return AmbientMotionVector(dx: 0, dy: 0)
        }
        return AmbientMotionVector(
            dx: offsetX / distance * strength,
            dy: offsetY / distance * strength
        )
    }

    public static func boundaryVector(
        positionX: Double,
        positionY: Double,
        width: Double,
        height: Double
    ) -> AmbientMotionVector {
        AmbientMotionVector(
            dx: boundaryStrength(distanceToEdge: positionX)
                - boundaryStrength(distanceToEdge: width - positionX),
            dy: boundaryStrength(distanceToEdge: positionY)
                - boundaryStrength(distanceToEdge: height - positionY)
        )
    }

    public static func familyVector(
        childX: Double,
        childY: Double,
        parentX: Double,
        parentY: Double,
        clockwise: Bool
    ) -> AmbientMotionVector {
        let offsetX = parentX - childX
        let offsetY = parentY - childY
        let distance = hypot(offsetX, offsetY)
        guard distance > 0 else { return AmbientMotionVector(dx: 0, dy: 0) }
        let steering = familySteering(distance: distance, clockwise: clockwise)
        let directionX = offsetX / distance
        let directionY = offsetY / distance
        return AmbientMotionVector(
            dx: directionX * steering.radial - directionY * steering.tangential,
            dy: directionY * steering.radial + directionX * steering.tangential
        )
    }

    public static func encounterVector(
        originX: Double,
        originY: Double,
        otherX: Double,
        otherY: Double,
        clockwise: Bool
    ) -> AmbientMotionVector {
        let offsetX = originX - otherX
        let offsetY = originY - otherY
        let distance = hypot(offsetX, offsetY)
        guard distance > 0 else { return AmbientMotionVector(dx: 0, dy: 0) }
        let strength = encounterTangentialStrength(
            distance: distance,
            clockwise: clockwise
        )
        return AmbientMotionVector(
            dx: -offsetY / distance * strength,
            dy: offsetX / distance * strength
        )
    }
}
