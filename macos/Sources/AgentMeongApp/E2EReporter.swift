import Foundation

struct E2EReporter {
    private static let allowedEvents: Set<String> = [
        "hook_status",
        "launched",
        "observation",
        "popover_active",
        "popover_closed",
        "popover_opened",
    ]
    private static let allowedFieldNames: Set<String> = [
        "activeActorCount",
        "aggregateState",
        "childAbsorptions",
        "childBirths",
        "completionNotified",
        "completionUnseen",
        "connectionGuidanceVisible",
        "hookInstalled",
        "liveActorCount",
        "onboardingNeeded",
        "popoverBehavior",
        "receiverReady",
    ]
    private let reportPath = ProcessInfo.processInfo.environment["AGENT_MEONG_E2E_REPORT"]

    var isEnabled: Bool { reportPath != nil }

    func record(_ event: String, fields: [String: Any] = [:]) {
        guard let reportPath else { return }
        let isAllowed = Self.allowedEvents.contains(event)
            && Set(fields.keys).isSubset(of: Self.allowedFieldNames)
        var payload = isAllowed ? fields : [:]
        payload["event"] = isAllowed ? event : "privacy_violation"
        guard
            JSONSerialization.isValidJSONObject(payload),
            var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return }
        data.append(10)

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: reportPath) {
            _ = fileManager.createFile(atPath: reportPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: reportPath) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }
}
