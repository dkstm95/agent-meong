import Foundation

struct E2EReporter {
    private static let allowedEvents: Set<String> = [
        "completion_receipts_accessibility_retained",
        "completion_receipts_presented",
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
        "popover_closing",
        "popover_geometry",
        "popover_opened",
        "state_legend_completed",
        "state_legend_dismissed",
        "state_legend_shown",
    ]
    private static let allowedFieldNames: Set<String> = [
        "accessibilityMenuAction",
        "activeTailsLegible",
        "activeActorCount",
        "aggregateState",
        "attentionAccessibilityNotified",
        "attentionActorCount",
        "attentionCountAccessible",
        "childAbsorptions",
        "childBirths",
        "completionReceiptCount",
        "completionReceiptAccessibilityCleared",
        "completionReceiptsAcknowledged",
        "completionReceiptsAccessible",
        "connectionActionVisible",
        "connectionAction",
        "connectionStatus",
        "connectionStatusConsistent",
        "connectionGuidanceLayoutValid",
        "connectionGuidanceScrollable",
        "connectionProgressVisible",
        "currentHookConfirmed",
        "customActorPreserved",
        "customConfirmationPreserved",
        "defaultActorsRemaining",
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
        "inlineAdvisory",
        "liveActorCount",
        "language",
        "localizedSample",
        "managedHookPresent",
        "onboardingNeeded",
        "otherPendingHookCount",
        "popoverBehavior",
        "popoverBehaviorRestored",
        "popoverOpen",
        "processID",
        "receiverReady",
        "reviewLaunchSucceeded",
        "reviewRecoveryGuidanceVisible",
        "reduceMotionEnabled",
        "runtimeStatus",
        "sceneStaticActiveCue",
        "sceneStatusColorsCorrect",
        "separateConnectionConfirmed",
        "separateForgetVisible",
        "recentRefreshSeconds",
        "rejectedEventCount",
        "sameScreen",
        "stateLegendAccessible",
        "stateLegendColorGuideContained",
        "stateLegendColorGuideVisible",
        "stateLegendDismissible",
        "stateLegendDismissSucceeded",
        "stateLegendObjectSwatchCount",
        "stateLegendHelpIcon",
        "stateLegendLayoutValid",
        "stateLegendManual",
        "stateLegendPreviouslySeen",
        "stateLegendReduceMotionStatic",
        "stateLegendScope",
        "stateLegendStackContained",
        "stateLegendStatusSwatchCount",
        "stateLegendTextUnclipped",
        "stateLegendToolActivityVisible",
        "stateLegendVersion",
        "stateLegendVisible",
        "staleHookResultsDiscarded",
        "statusItemStaticActiveCue",
        "statusSpotlightQueueDepth",
        "statusSpotlightState",
        "toolFinishes",
        "toolImpulseCount",
        "toolStarts",
        "unseenWorkEndCount",
        "minuteRefreshSeconds",
        "hourRefreshSeconds",
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
