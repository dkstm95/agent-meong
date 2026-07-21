import AgentMeongCore
import AppKit

/// Marker and motion present observed state without changing agent identity.
/// Decorative movement remains separate so it never invents state.
enum StateMarkerKind {
    case activeTick
    case approvalRing
    case uncertainSegments
    case finishedArc
    case completedHalo
    case cancelledBar
    case failedDiamond
}

struct StatePresentation {
    let bodyAlpha: CGFloat
    let marker: StateMarkerKind?
    let accentColor: NSColor?
    let markerAlpha: CGFloat
    let pulseDuration: TimeInterval?
    let breatheDuration: TimeInterval?

    static func make(for state: VisualState, increaseContrast: Bool) -> StatePresentation {
        switch state {
        case .quiet:
            StatePresentation(
                bodyAlpha: increaseContrast ? 0.88 : 0.62,
                marker: nil,
                accentColor: nil,
                markerAlpha: 0,
                pulseDuration: nil,
                breatheDuration: 2.8
            )
        case .active:
            StatePresentation(
                bodyAlpha: 1,
                marker: nil,
                accentColor: nil,
                markerAlpha: 0,
                pulseDuration: nil,
                breatheDuration: 1.8
            )
        case .attention:
            StatePresentation(
                bodyAlpha: 1,
                marker: .approvalRing,
                accentColor: AgentMeongPalette.statusColor(for: .attention),
                markerAlpha: increaseContrast ? 0.94 : 0.76,
                pulseDuration: 1.4,
                breatheDuration: nil
            )
        case .uncertain:
            StatePresentation(
                bodyAlpha: increaseContrast ? 0.86 : 0.54,
                marker: .uncertainSegments,
                accentColor: AgentMeongPalette.statusColor(for: .uncertain),
                markerAlpha: increaseContrast ? 0.82 : 0.48,
                pulseDuration: 3.2,
                breatheDuration: nil
            )
        case .finished:
            StatePresentation(
                bodyAlpha: increaseContrast ? 0.90 : 0.68,
                marker: .finishedArc,
                accentColor: AgentMeongPalette.statusColor(for: .finished),
                markerAlpha: increaseContrast ? 0.94 : 0.68,
                pulseDuration: nil,
                breatheDuration: nil
            )
        case .completed:
            StatePresentation(
                bodyAlpha: increaseContrast ? 0.92 : 0.70,
                marker: .completedHalo,
                accentColor: AgentMeongPalette.statusColor(for: .completed),
                markerAlpha: increaseContrast ? 0.96 : 0.72,
                pulseDuration: nil,
                breatheDuration: nil
            )
        case .cancelled:
            StatePresentation(
                bodyAlpha: increaseContrast ? 0.84 : 0.50,
                marker: .cancelledBar,
                accentColor: AgentMeongPalette.statusColor(for: .cancelled),
                markerAlpha: increaseContrast ? 0.94 : 0.62,
                pulseDuration: nil,
                breatheDuration: nil
            )
        case .failed:
            StatePresentation(
                bodyAlpha: 1,
                marker: .failedDiamond,
                accentColor: AgentMeongPalette.statusColor(for: .failed),
                markerAlpha: increaseContrast ? 1 : 0.82,
                pulseDuration: 2.1,
                breatheDuration: nil
            )
        }
    }
}
