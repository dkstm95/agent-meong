import AgentMeongCore
import AppKit

enum AgentMeongPalette {
    static func statusColor(for state: VisualState) -> NSColor {
        switch state {
        case .quiet: NSColor(srgbRed: 0.28, green: 0.72, blue: 0.96, alpha: 1)
        case .active: NSColor(srgbRed: 0.04, green: 0.84, blue: 1.00, alpha: 1)
        case .attention: NSColor(srgbRed: 1.00, green: 0.62, blue: 0.12, alpha: 1)
        case .uncertain: NSColor(srgbRed: 0.58, green: 0.62, blue: 0.78, alpha: 1)
        case .finished: NSColor(srgbRed: 0.54, green: 0.72, blue: 0.88, alpha: 1)
        case .completed: NSColor(srgbRed: 0.70, green: 0.55, blue: 1.00, alpha: 1)
        case .cancelled: NSColor(srgbRed: 0.50, green: 0.55, blue: 0.62, alpha: 1)
        case .failed: NSColor(srgbRed: 0.96, green: 0.24, blue: 0.34, alpha: 1)
        }
    }
}
