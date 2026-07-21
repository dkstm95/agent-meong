import AgentMeongCore
import AppKit

enum AgentMeongPalette {
    private static let agentColors: [NSColor] = [
        NSColor(srgbRed: 0.62, green: 0.88, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.78, green: 0.72, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.91, blue: 0.79, alpha: 1),
        NSColor(srgbRed: 0.96, green: 0.82, blue: 0.70, alpha: 1),
        NSColor(srgbRed: 0.72, green: 0.81, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.92, green: 0.72, blue: 0.84, alpha: 1),
        NSColor(srgbRed: 0.88, green: 0.91, blue: 0.72, alpha: 1),
        NSColor(srgbRed: 0.90, green: 0.91, blue: 0.94, alpha: 1),
    ]

    static func agentColor(slot: Int) -> NSColor {
        agentColors[slot % agentColors.count]
    }

    static var agentColorCount: Int { agentColors.count }

    static func agentColorSlot(seed: UInt64) -> Int {
        let mixed = seed ^ (seed >> 16) ^ (seed >> 32)
        return Int(mixed % UInt64(agentColors.count))
    }

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
