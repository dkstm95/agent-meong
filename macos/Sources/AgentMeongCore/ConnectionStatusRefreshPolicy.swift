import Foundation

public enum ConnectionStatusRefreshPolicy {
    public static let readyRefreshInterval: TimeInterval = 5 * 60

    public static func shouldRefreshOnPopoverOpen(
        runtimeIsReady: Bool,
        lastCompletedAt: Date?,
        now: Date
    ) -> Bool {
        guard runtimeIsReady, let lastCompletedAt else { return true }
        let age = now.timeIntervalSince(lastCompletedAt)
        return age < 0 || age >= readyRefreshInterval
    }
}
