import Foundation

/// Production cadence for briefly re-reading an approval state that changes
/// outside the app. A later popover open starts a fresh bounded burst.
public enum ConnectionReviewRefreshPolicy {
    public static let initialDelays: [TimeInterval] = [1, 2.5, 6, 15, 24]
    public static let steadyDelay: TimeInterval = 24
    public static let maximumAttemptCount = 5

    public static func delay(afterCompletedAttempts attempts: Int) -> TimeInterval? {
        let index = max(0, attempts)
        guard index < maximumAttemptCount else { return nil }
        guard index < initialDelays.count else { return steadyDelay }
        return initialDelays[index]
    }
}
