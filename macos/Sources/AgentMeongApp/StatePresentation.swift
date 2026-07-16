import AgentMeongCore
import AppKit

/// The state signal is deliberately separate from an actor's identity color.
/// A family keeps one hue while the marker supplies a color-independent shape.
enum StateMarkerKind {
    case approvalRing
    case uncertainSegments
    case finishedArc
    case completedHalo
    case cancelledBar
    case failedDiamond
}

struct StatePresentation {
    let bodyAlpha: CGFloat
    let tailAlpha: CGFloat
    let marker: StateMarkerKind?
    let accentColor: NSColor?
    let markerAlpha: CGFloat
    let pulseDuration: TimeInterval?
    let breatheDuration: TimeInterval?

    static func make(for motion: MotionMode, increaseContrast: Bool) -> StatePresentation {
        switch motion {
        case .drift:
            StatePresentation(
                bodyAlpha: increaseContrast ? 0.88 : 0.62,
                tailAlpha: increaseContrast ? 0.32 : 0.16,
                marker: nil,
                accentColor: nil,
                markerAlpha: 0,
                pulseDuration: nil,
                breatheDuration: 2.8
            )
        case .flow:
            StatePresentation(
                bodyAlpha: 1,
                tailAlpha: increaseContrast ? 0.68 : 0.48,
                marker: nil,
                accentColor: nil,
                markerAlpha: 0,
                pulseDuration: nil,
                breatheDuration: 1.8
            )
        case .wait:
            StatePresentation(
                bodyAlpha: 1,
                tailAlpha: increaseContrast ? 0.24 : 0.08,
                marker: .approvalRing,
                accentColor: NSColor(srgbRed: 0.98, green: 0.68, blue: 0.24, alpha: 1),
                markerAlpha: increaseContrast ? 0.94 : 0.76,
                pulseDuration: 1.4,
                breatheDuration: nil
            )
        case .uncertain:
            StatePresentation(
                bodyAlpha: increaseContrast ? 0.86 : 0.54,
                tailAlpha: increaseContrast ? 0.20 : 0.05,
                marker: .uncertainSegments,
                accentColor: NSColor(srgbRed: 0.60, green: 0.66, blue: 0.74, alpha: 1),
                markerAlpha: increaseContrast ? 0.82 : 0.48,
                pulseDuration: 3.2,
                breatheDuration: nil
            )
        case .finished:
            StatePresentation(
                bodyAlpha: increaseContrast ? 0.90 : 0.68,
                tailAlpha: increaseContrast ? 0.18 : 0.04,
                marker: .finishedArc,
                accentColor: NSColor(srgbRed: 0.54, green: 0.76, blue: 0.94, alpha: 1),
                markerAlpha: increaseContrast ? 0.94 : 0.68,
                pulseDuration: nil,
                breatheDuration: nil
            )
        case .ripple:
            StatePresentation(
                bodyAlpha: increaseContrast ? 0.92 : 0.70,
                tailAlpha: increaseContrast ? 0.18 : 0.04,
                marker: .completedHalo,
                accentColor: NSColor(srgbRed: 0.74, green: 0.68, blue: 0.98, alpha: 1),
                markerAlpha: increaseContrast ? 0.96 : 0.72,
                pulseDuration: nil,
                breatheDuration: nil
            )
        case .cancelled:
            StatePresentation(
                bodyAlpha: increaseContrast ? 0.84 : 0.50,
                tailAlpha: increaseContrast ? 0.16 : 0.03,
                marker: .cancelledBar,
                accentColor: NSColor(srgbRed: 0.62, green: 0.66, blue: 0.72, alpha: 1),
                markerAlpha: increaseContrast ? 0.94 : 0.62,
                pulseDuration: nil,
                breatheDuration: nil
            )
        case .failed:
            StatePresentation(
                bodyAlpha: 1,
                tailAlpha: increaseContrast ? 0.22 : 0.05,
                marker: .failedDiamond,
                accentColor: NSColor(srgbRed: 0.92, green: 0.36, blue: 0.42, alpha: 1),
                markerAlpha: increaseContrast ? 1 : 0.82,
                pulseDuration: 2.1,
                breatheDuration: nil
            )
        }
    }
}
