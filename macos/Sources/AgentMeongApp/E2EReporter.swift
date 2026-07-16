import Foundation

struct E2EReporter {
    private static let allowedEvents: Set<String> = [
        "connection_forget",
        "hook_installation",
        "hook_removal",
        "hook_status",
        "launched",
        "localization",
        "observation",
        "observation_rejected",
        "popover_active",
        "popover_closed",
        "popover_geometry",
        "popover_opened",
    ]
    private static let allowedFieldNames: Set<String> = [
        "activeActorCount",
        "aggregateState",
        "childAbsorptions",
        "childBirths",
        "workEndNotified",
        "workEndUnseen",
        "connectionGuidanceVisible",
        "confirmationCleared",
        "anchorAligned",
        "fitsVisibleScreen",
        "hookInstalled",
        "hooksCommandCopied",
        "hookState",
        "horizontallyAligned",
        "inlineHooksPresent",
        "liveActorCount",
        "language",
        "localizedSample",
        "managedHookPresent",
        "onboardingNeeded",
        "popoverBehavior",
        "processID",
        "receiverReady",
        "rejectedEventCount",
        "sameScreen",
        "verticallyAttached",
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
