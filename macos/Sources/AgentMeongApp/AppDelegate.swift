import AgentMeongCore
import AppKit
import SpriteKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private enum HookMutationKind {
        case install
        case uninstall
    }

    private struct HookMutationRequest {
        let kind: HookMutationKind
        let generation: UInt
        let affectedInstanceID: String?
    }

    private enum PopoverVisibility {
        case closed
        case opening
        case open
        case closing
    }

    private static let stateLegendVersion = 1
    private static let receiverHealthCheckInterval: TimeInterval = 30

    private var popover: NSPopover?
    private var popoverVisibility: PopoverVisibility = .closed
    private var presentedCompletionReceiptAccessibilityCount = 0
    private weak var popoverPositioningView: NSView?
    private var scene: MeongScene?
    private var sceneView: SKView?
    private var connectionOverlay: ConnectionOverlayView?
    private var statusController: StatusItemController?
    private var ticker: Timer?
    private var receiverHealthTicker: Timer?
    private var reducer = WorldReducer()
    private var socketServer: EventSocketServer?
    private var lastEventAt: Date?
    private var previouslyConfirmedAt: Date?
    private var lastObservedIntegrationVersion: String?
    private var lastObservedIntegrationInstance: String?
    private var confirmationLedger = ConnectionConfirmationLedger()
    private var observedInstancesThisRun: Set<String> = []
    private var pendingConfirmationAt: Date?
    private var pendingConfirmationDefinitionID: String?
    private var pendingConfirmationInstanceID: String?
    private var shouldBindE2EConfirmationToCurrentDefinition = false
    private var didAutoConnectForE2E = false
    private var didAutoForgetForE2E = false
    private var didAutoRemoveHookForE2E = false
    private var didAutoCloseStateLegendForE2E = false
    private var didAutoReopenStateLegendForE2E = false
    private var didAutoShowStateLegendHelpForE2E = false
    private var didScheduleCompletionReceiptOpenForE2E = false
    private var pendingClosingObservationForE2E: ActivityObservation?
    private var isHoldingStateLegendRetryPopoverForE2E = false
    private var didResolvePersistedConfirmation = false
    private var rejectedEventCount = 0
    private var receiverError: String?
    private var isDemo = false
    private var didReportActivePopover = false
    private var stateLegendPending = false
    private var stateLegendInFlight = false
    private var stateLegendSeenThisRun = false
    private let hookInstaller = CodexHookInstaller()
    private let reviewLauncher = CodexReviewLauncher()
    private var hookInstallationState: CodexHookInstallationState = .checking
    private var inlineHooksPresent = false
    private var managedHookPresent = false
    private var currentHookDefinitionID: String?
    private var currentHookInstanceID: String?
    private var lastKnownDefaultHookInstanceID: String?
    private var hookRuntimeStatus: CodexHookRuntimeStatus = .checking
    private var runtimeProblemEvents: [String] = []
    private var otherPendingHookCount: Int?
    private var reviewLaunchState: CodexReviewLaunchState = .idle
    private var didRefreshRuntimeAfterObservation = false
    private var hookStatusRefreshInFlight = false
    private var hookStatusRefreshPending = false
    private var lastCompletedHookStatusRefreshAt: Date?
    private var pendingHookStatusOpenOnboarding = false
    private var pendingHookStatusPreservesVisibleState = false
    private var hookConfigurationGeneration: UInt = 0
    private var activeHookMutation: HookMutationRequest?
    private var pendingHookMutation: HookMutationRequest?
    private var discardedHookResultCount = 0
    private var reviewStatusRefreshAttempt = 0
    private var reviewStatusRefreshWorkItem: DispatchWorkItem?
    private let e2eReporter = E2EReporter()
    private let lastConfirmedEventKey = "lastConfirmedCodexEventAt"
    private let lastConfirmedDefinitionKey = "lastConfirmedCodexHookDefinition"
    private let lastConfirmedInstanceKey = "lastConfirmedCodexHookInstance"
    private let confirmationLedgerKey = "connectionConfirmationLedgerV1"
    private let lastKnownDefaultHookInstanceKey = "lastKnownDefaultHookInstanceV1"
    private let stateLegendVersionKey = "stateLegendSeenVersion"
    private lazy var connectionDefaults: UserDefaults = {
        guard
            e2eReporter.isEnabled,
            let suiteName = ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_DEFAULTS_SUITE"
            ],
            !suiteName.isEmpty,
            let defaults = UserDefaults(suiteName: suiteName)
        else { return .standard }
        return defaults
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateExistingInstanceIfNeeded() { return }
        isDemo = ProcessInfo.processInfo.environment["AGENT_MEONG_DEMO"] == "1"
        if ProcessInfo.processInfo.environment["AGENT_MEONG_E2E_PREVIOUSLY_CONFIRMED"] == "1" {
            pendingConfirmationAt = .now.addingTimeInterval(-60)
            shouldBindE2EConfirmationToCurrentDefinition = true
        } else if shouldPersistConnectionHistory {
            lastKnownDefaultHookInstanceID = connectionDefaults.string(
                forKey: lastKnownDefaultHookInstanceKey
            )
            loadConnectionHistory()
        }
        if previouslyConfirmedAt != nil, shouldPersistWorldState {
            restorePersistedWorld(at: .now)
        }
        if isDemo {
            loadDemoWorld()
        }
        let world = reducer.state
        let scene = MeongScene(size: CGSize(width: 460, height: 500))
        scene.sync(with: world.intents)
        scene.setReduceMotion(reduceMotionEnabled)
        scene.setIncreaseContrast(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)

        let popover = makePopover(scene: scene)
        let statusController = StatusItemController(
            state: world.aggregateState,
            liveCount: world.liveActorCount,
            activeCount: world.activeActorCount,
            attentionActorCount: world.attentionActorCount,
            sourceLabel: connectionLabel(at: .now)
        )
        statusController.delegate = self

        self.scene = scene
        self.popover = popover
        self.statusController = statusController
        scene.isPaused = true
        startEventServer()
        startReceiverHealthChecks()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        render(world, at: .now)
        scheduleNextTick()
        e2eReporter.record("launched", fields: [
            "accessibilityMenuAction": statusController.hasAccessibilityMenuAction,
            "connectionProgressVisible": connectionOverlay?
                .isConnectionProgressVisibleForE2E ?? false,
            "connectionStatus": ConnectionStatusPresentation.make(
                diagnostics: connectionDiagnostics,
                now: .now
            ).kind.rawValue,
            "processID": Int(ProcessInfo.processInfo.processIdentifier),
            "receiverReady": receiverReady,
            "popoverBehavior": popover.behavior == .transient ? "transient" : "other",
        ])
        if ProcessInfo.processInfo.environment[
            "AGENT_MEONG_E2E_REPORT_LOCALIZATION"
        ] == "1" {
            let scheduleNow = Date(timeIntervalSinceReferenceDate: 10_000)
            e2eReporter.record("localization", fields: [
                "hourRefreshSeconds": Int(L10n.relativeAgeRefreshDelay(
                    from: scheduleNow.addingTimeInterval(-3_700),
                    to: scheduleNow
                )),
                "language": L10n.language.rawValue,
                "localizedSample": L10n.text("Codex 연결", "Connect Codex"),
                "minuteRefreshSeconds": Int(L10n.relativeAgeRefreshDelay(
                    from: scheduleNow.addingTimeInterval(-75),
                    to: scheduleNow
                )),
                "recentRefreshSeconds": Int(L10n.relativeAgeRefreshDelay(
                    from: scheduleNow.addingTimeInterval(-15),
                    to: scheduleNow
                )),
            ])
        }

        let debugOpen = ProcessInfo.processInfo.environment["AGENT_MEONG_DEBUG_OPEN"] == "1"
        let suppressOpen = ProcessInfo.processInfo.environment["AGENT_MEONG_E2E_SUPPRESS_OPEN"] == "1"
        let shouldOpenOnboarding = !debugOpen && !suppressOpen
        let shouldShowInitialConnectionProgress = shouldOpenOnboarding
            && previouslyConfirmedAt == nil
        if !isDemo {
            refreshHookStatus(
                openOnboarding: shouldOpenOnboarding
                    && !shouldShowInitialConnectionProgress
            )
            if shouldShowInitialConnectionProgress {
                // The Codex status probe can take tens of seconds while it
                // checks independently updated app and CLI candidates. Show
                // useful progress immediately instead of leaving a first-run
                // user staring at a silent menu-bar icon.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                    self?.presentInitialConnectionProgress()
                }
            }
            if shouldAutoConnectDuringInitialStatusForE2E {
                didAutoConnectForE2E = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.installCodexHook()
                }
            }
        }
        if debugOpen {
            DispatchQueue.main.async {
                statusController.presentMeongSpace()
            }
        }
    }

    func popoverWillClose(_ notification: Notification) {
        popoverVisibility = .closing
        e2eReporter.record("popover_closing")
        if let pendingObservation = pendingClosingObservationForE2E {
            pendingClosingObservationForE2E = nil
            receive(pendingObservation)
        }
        cancelStateLegendForRetry()
        scene?.discardTransientPresentation()
    }

    func popoverDidClose(_ notification: Notification) {
        popoverVisibility = .closed
        presentedCompletionReceiptAccessibilityCount = 0
        let clearedAccessibilitySummary = sceneAccessibilitySummary(
            reducer.state,
            completionReceiptCount: 0
        )
        sceneView?.setAccessibilityValue(clearedAccessibilitySummary)
        if isHoldingStateLegendRetryPopoverForE2E {
            isHoldingStateLegendRetryPopoverForE2E = false
            popover?.behavior = .transient
        }
        cancelStateLegendForRetry()
        scene?.discardTransientPresentation()
        scene?.isPaused = true
        popoverPositioningView = nil
        didReportActivePopover = false
        e2eReporter.record("popover_closed", fields: [
            "completionReceiptAccessibilityCleared": sceneView?
                .accessibilityValue() as? String == clearedAccessibilitySummary,
            "completionReceiptCount": presentedCompletionReceiptAccessibilityCount,
            "toolImpulseCount": scene?.maximumToolImpulseCountForE2E ?? 0,
        ])
        autoOpenCompletionReceiptsForE2EIfNeeded()
        autoReopenStateLegendForE2EIfNeeded()
    }

    func popoverDidShow(_ notification: Notification) {
        popoverVisibility = .open
        e2eReporter.record("popover_opened")
        presentCompletionReceiptsAfterPopoverDidShow()
        presentPendingStateLegendIfPossible()
        reportActivePopoverIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.autoShowStateLegendHelpForE2EIfNeeded()
        }
        guard e2eReporter.isEnabled else { return }
        // NSPopover posts didShow while its window can still be finishing the
        // system animation. Sample the settled frame so the E2E check measures
        // the real attachment instead of a transition frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let positioningView = self.popoverPositioningView else {
                return
            }
            self.reportPopoverGeometry(relativeTo: positioningView)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        checkReceiverHealth()
        reportActivePopoverIfNeeded()
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard
            !isHoldingStateLegendRetryPopoverForE2E,
            popover?.isShown == true
        else { return }
        popover?.close()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ticker?.invalidate()
        receiverHealthTicker?.invalidate()
        reviewStatusRefreshWorkItem?.cancel()
        socketServer?.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    private func loadDemoWorld() {
        DemoFixture.observations().forEach { reducer.apply($0) }
        reducer.expire(at: .now)
    }

    private func restorePersistedWorld(at now: Date) {
        do {
            if let checkpoint = try worldCheckpointStore.load() {
                reducer.restore(checkpoint, at: now)
                try worldCheckpointStore.save(reducer.state)
            }
        } catch {
            try? worldCheckpointStore.clear()
        }
    }

    private func persistWorldState() {
        guard shouldPersistWorldState else { return }
        try? worldCheckpointStore.save(reducer.state)
    }

    private func activateExistingInstanceIfNeeded() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard
            environment["AGENT_MEONG_E2E_REPORT"] == nil,
            environment["AGENT_MEONG_SOCKET"] == nil,
            environment["AGENT_MEONG_DEBUG_DOCK"] == nil,
            let identifier = Bundle.main.bundleIdentifier
        else { return false }

        let currentProcess = ProcessInfo.processInfo.processIdentifier
        guard let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != currentProcess })
        else { return false }
        existing.activate()
        NSApp.terminate(nil)
        return true
    }

    @objc private func tick() {
        ticker = nil
        let now = Date.now
        let previousState = reducer.state
        let state = reducer.expire(at: now)
        if state != previousState {
            persistWorldState()
        }
        render(state, at: now)
        scheduleNextTick()
    }

    @objc private func checkReceiverHealth() {
        guard !receiverReady else { return }
        startEventServer()
    }

    private func startReceiverHealthChecks() {
        receiverHealthTicker?.invalidate()
        let timer = Timer(
            timeInterval: Self.receiverHealthCheckInterval,
            target: self,
            selector: #selector(checkReceiverHealth),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        receiverHealthTicker = timer
    }

    private func startEventServer() {
        socketServer?.stop()
        let server = EventSocketServer(
            path: ProcessInfo.processInfo.environment["AGENT_MEONG_SOCKET"]
                ?? EventSocketServer.defaultPath,
            onObservation: { [weak self] observation in self?.receive(observation) },
            onRejected: { [weak self] reason in self?.rejectEvent(reason) }
        )
        do {
            try server.start()
            socketServer = server
            receiverError = nil
            render(reducer.state, at: .now)
        } catch {
            socketServer = nil
            receiverError = error.localizedDescription
            render(reducer.state, at: .now)
        }
    }

    private func receive(_ observation: ActivityObservation) {
        guard !isDemo else { return }
        if e2eReporter.isEnabled,
            ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_DEFER_STOP_UNTIL_POPOVER_CLOSING"
            ] == "1",
            observation.kind == .turnStopping,
            popoverVisibility == .open,
            pendingClosingObservationForE2E == nil
        {
            pendingClosingObservationForE2E = observation
            popover?.performClose(nil)
            return
        }
        let receivedAt = Date.now
        lastEventAt = receivedAt
        previouslyConfirmedAt = receivedAt
        lastObservedIntegrationVersion = observation.integrationVersion
        lastObservedIntegrationInstance = observation.integrationInstance
        if let integrationInstance = observation.integrationInstance {
            confirmationLedger.record(
                instanceID: integrationInstance,
                definitionID: observation.integrationVersion,
                at: receivedAt
            )
            observedInstancesThisRun.insert(integrationInstance)
        }
        if shouldPersistConnectionHistory {
            persistConnectionHistory()
        }
        rejectedEventCount = 0
        let update = reducer.applyWithEffects(observation)
        if update.observationAccepted {
            persistWorldState()
        }
        let effects = popoverVisibility == .open ? update.effects : []
        let transitions = render(update.state, at: receivedAt, effects: effects)
        let completionReceipts = update.effects.compactMap(completionReceipt)
        let endedTopLevelWork = !completionReceipts.isEmpty
        var workEndUnseen = false
        if endedTopLevelWork {
            if popoverVisibility != .open {
                completionReceipts.forEach { receipt in
                    // A later lifecycle event may omit ownership metadata.
                    // The reducer deliberately preserves the actor's known
                    // owner, so receipts must use that resolved owner too.
                    let receiptIntegrationInstance = update.state
                        .knownIntegrationInstance(for: receipt.actorId)
                        ?? observation.integrationInstance
                    scene?.registerCompletionReceipt(
                        for: receipt.actorId,
                        kind: receipt.kind,
                        integrationInstance: receiptIntegrationInstance
                    )
                }
            }
            let unseenCount = scene?.pendingCompletionReceiptCount ?? 0
            workEndUnseen = (statusController?.notifyWorkEnded(
                reduceMotion: reduceMotionEnabled,
                unseenCount: unseenCount
            ) ?? 0) > 0
        }
        scheduleNextTick()
        if update.observationAccepted {
            queueStateLegendAfterAcceptedObservation()
            let diagnostics = connectionDiagnostics
            let connectionPresentation = ConnectionStatusPresentation.make(
                diagnostics: diagnostics,
                now: receivedAt
            )
            e2eReporter.record("observation", fields: [
                "activeActorCount": update.state.activeActorCount,
                "aggregateState": update.state.aggregateState.rawValue,
                "attentionAccessibilityNotified": statusController?
                    .didAnnounceAttentionIncreaseOnLastUpdate ?? false,
                "attentionActorCount": update.state.attentionActorCount,
                "attentionCountAccessible": statusController?.isAttentionCountAccessible ?? false,
                "childAbsorptions": transitions.childAbsorptions,
                "childBirths": transitions.childBirths,
                "connectionGuidanceVisible": connectionOverlay?.isGuidanceVisible ?? false,
                "connectionStatus": connectionPresentation.kind.rawValue,
                "connectionStatusConsistent": statusController?
                    .matchesConnectionLabelForE2E(connectionPresentation.menuLabel) == true
                    && connectionOverlay?.matchesConnectionPresentationForE2E(
                        connectionPresentation
                    ) == true,
                "currentHookConfirmed": diagnostics.currentHookConfirmedAt != nil,
                "workEndNotified": endedTopLevelWork,
                "workEndUnseen": workEndUnseen,
                "liveActorCount": update.state.liveActorCount,
                "onboardingNeeded": diagnostics.needsOnboarding,
                "reduceMotionEnabled": reduceMotionEnabled,
                "sceneStaticActiveCue": scene?
                    .isReduceMotionActiveSceneStaticForE2E ?? false,
                "separateConnectionConfirmed": diagnostics
                    .hasSeparateConnectionConfirmation,
                "separateForgetVisible": connectionOverlay?
                    .isSeparateForgetVisibleForE2E ?? false,
                "statusItemStaticActiveCue": statusController?
                    .isReduceMotionActiveImageStaticForE2E ?? false,
                "toolFinishes": transitions.toolFinishes,
                "toolImpulseCount": scene?.maximumToolImpulseCountForE2E ?? 0,
                "toolStarts": transitions.toolStarts,
                "unseenWorkEndCount": scene?.pendingCompletionReceiptCount ?? 0,
            ])
            autoForgetSeparateConnectionForE2EIfNeeded()
            autoRemoveCurrentHookForE2EIfNeeded()
            autoOpenCompletionReceiptsForE2EIfNeeded()
            if observation.integrationInstance == currentHookInstanceID,
                hookRuntimeStatus != .ready,
                !didRefreshRuntimeAfterObservation
            {
                didRefreshRuntimeAfterObservation = true
                refreshHookStatus(
                    openOnboarding: false,
                    preserveVisibleState: true
                )
            }
        }
    }

    private func completionReceipt(
        for effect: WorldEffect
    ) -> (actorId: String, kind: CompletionReceiptKind)? {
        switch effect {
        case let .topLevelFinished(actorId):
            (actorId, .finished)
        case let .topLevelCompleted(actorId):
            (actorId, .completed)
        case .childStarted, .childFinished, .childCompleted, .toolStarted, .toolFinished:
            nil
        }
    }

    private func rejectEvent(_ reason: String) {
        rejectedEventCount += 1
        receiverError = nil
        render(reducer.state, at: .now)
        e2eReporter.record("observation_rejected", fields: [
            "rejectedEventCount": rejectedEventCount,
        ])
        if e2eReporter.isEnabled,
            ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_AUTO_REFRESH_REJECTED"
            ] == "1",
            rejectedEventCount == 1
        {
            DispatchQueue.main.async { [weak self] in
                self?.connectionOverlay?.performPrimaryActionForE2E()
            }
        }
    }

    @discardableResult
    private func render(
        _ state: WorldState,
        at now: Date,
        effects: [WorldEffect] = []
    ) -> SceneTransitionSummary {
        let reduceMotion = reduceMotionEnabled
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        scene?.setReduceMotion(reduceMotion)
        scene?.setIncreaseContrast(increaseContrast)
        let transitions = scene?.sync(with: state.intents, effects: effects) ?? SceneTransitionSummary()
        statusController?.update(
            state: state.aggregateState,
            liveCount: state.liveActorCount,
            activeCount: state.activeActorCount,
            attentionActorCount: state.attentionActorCount,
            sourceLabel: connectionLabel(at: now),
            reduceMotion: reduceMotion,
            increaseContrast: increaseContrast
        )
        popover?.animates = !reduceMotion
        connectionOverlay?.setReduceMotion(reduceMotion)
        connectionOverlay?.setIncreaseContrast(increaseContrast)
        connectionOverlay?.update(connectionDiagnostics, now: now)
        reconcileStateLegendPresentation()
        presentPendingStateLegendIfPossible()
        sceneView?.setAccessibilityValue(sceneAccessibilitySummary(
            state,
            completionReceiptCount: max(
                scene?.pendingCompletionReceiptCount ?? 0,
                presentedCompletionReceiptAccessibilityCount
            )
        ))
        sceneView?.setAccessibilityHelp(stateGrammarAccessibilityHelp)
        return transitions
    }

    private func makePopover(scene: MeongScene) -> NSPopover {
        let size = NSSize(width: 460, height: 500)
        let controller = NSViewController()
        let spaceView = MeongSpaceView(scene: scene, size: size)
        spaceView.connectionOverlay.onRetry = { [weak self] in self?.startEventServer() }
        spaceView.connectionOverlay.onInstall = { [weak self] in self?.installCodexHook() }
        spaceView.connectionOverlay.onReview = { [weak self] in self?.beginCodexReview() }
        spaceView.connectionOverlay.onRefreshHookStatus = { [weak self] in
            self?.refreshHookStatus(openOnboarding: false)
        }
        spaceView.connectionOverlay.onUninstall = { [weak self] in self?.uninstallCodexHook() }
        spaceView.connectionOverlay.onForget = { [weak self] in self?.forgetConnectionHistory() }
        spaceView.connectionOverlay.onShowStateLegend = { [weak self] in
            self?.showStateLegendManually()
        }
        spaceView.connectionOverlay.onStateLegendCancelled = { [weak self] in
            self?.stateLegendWasCancelled()
        }
        spaceView.connectionOverlay.onGuidanceDismissed = { [weak self] in
            self?.presentPendingStateLegendIfPossible()
        }
        connectionOverlay = spaceView.connectionOverlay
        sceneView = spaceView.sceneView
        controller.view = spaceView
        controller.view.appearance = NSAppearance(named: .darkAqua)
        controller.preferredContentSize = size

        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = size
        popover.behavior = .transient
        popover.animates = !reduceMotionEnabled
        popover.delegate = self
        return popover
    }

    private var connectionDiagnostics: ConnectionDiagnostics {
        ConnectionDiagnostics(
            receiverReady: receiverReady,
            lastEventAt: isDemo ? .now : lastEventAt,
            previouslyConfirmedAt: isDemo ? .now : previouslyConfirmedAt,
            rejectedEventCount: rejectedEventCount,
            receiverError: receiverError,
            hookInstallationState: hookInstallationState,
            inlineHooksPresent: inlineHooksPresent,
            managedHookPresent: managedHookPresent,
            hookRuntimeStatus: hookRuntimeStatus,
            runtimeProblemEvents: runtimeProblemEvents,
            otherPendingHookCount: otherPendingHookCount,
            reviewLaunchState: reviewLaunchState,
            hookProblemOverridesHistory: hookProblemOverridesHistory,
            currentHookConfirmedAt: currentHookInstanceID.flatMap {
                confirmationLedger.confirmation(instanceID: $0)?.confirmedAt
            },
            hasSeparateConnectionConfirmation: confirmationLedger.entries.contains {
                $0.instanceID != defaultHookReferenceID
            }
        )
    }

    private var defaultHookReferenceID: String? {
        currentHookInstanceID ?? lastKnownDefaultHookInstanceID
    }

    private func installCodexHook() {
        enqueueHookMutation(
            kind: .install,
            affectedInstanceID: currentHookInstanceID ?? lastKnownDefaultHookInstanceID
        )
    }

    private func uninstallCodexHook() {
        enqueueHookMutation(
            kind: .uninstall,
            affectedInstanceID: currentHookInstanceID ?? lastKnownDefaultHookInstanceID
        )
    }

    private func enqueueHookMutation(
        kind: HookMutationKind,
        affectedInstanceID: String?
    ) {
        hookConfigurationGeneration &+= 1
        let request = HookMutationRequest(
            kind: kind,
            generation: hookConfigurationGeneration,
            affectedInstanceID: affectedInstanceID
        )
        hookInstallationState = .checking
        hookRuntimeStatus = .checking
        runtimeProblemEvents = []
        otherPendingHookCount = nil
        reviewLaunchState = .idle
        didRefreshRuntimeAfterObservation = false
        reviewStatusRefreshWorkItem?.cancel()
        reviewStatusRefreshWorkItem = nil
        reviewStatusRefreshAttempt = 0
        render(reducer.state, at: .now)
        guard activeHookMutation == nil else {
            pendingHookMutation = request
            return
        }
        startHookMutation(request)
    }

    private func startHookMutation(_ request: HookMutationRequest) {
        activeHookMutation = request
        Task { [weak self] in
            guard let self else { return }
            let result: CodexHookInstallationResult
            switch request.kind {
            case .install:
                result = await hookInstaller.install()
            case .uninstall:
                result = await hookInstaller.uninstall()
            }
            completeHookMutation(request, with: result)
        }
    }

    private func completeHookMutation(
        _ request: HookMutationRequest,
        with result: CodexHookInstallationResult
    ) {
        guard activeHookMutation?.generation == request.generation else {
            discardedHookResultCount += 1
            return
        }
        activeHookMutation = nil

        let isLatestRequest = request.generation == hookConfigurationGeneration
            && pendingHookMutation == nil
        if isLatestRequest {
            switch request.kind {
            case .install:
                applyCompletedHookInstallation(
                    result,
                    replacedInstanceID: request.affectedInstanceID,
                    generation: request.generation
                )
            case .uninstall:
                applyCompletedHookRemoval(
                    result,
                    removedInstanceID: request.affectedInstanceID
                )
            }
        } else {
            discardedHookResultCount += 1
        }

        if let nextRequest = pendingHookMutation {
            pendingHookMutation = nil
            startHookMutation(nextRequest)
        } else {
            drainPendingHookStatusRefreshIfPossible()
        }
    }

    private func applyCompletedHookInstallation(
        _ result: CodexHookInstallationResult,
        replacedInstanceID: String?,
        generation: UInt
    ) {
        if result.state == .installed,
            let replacedInstanceID,
            replacedInstanceID != result.instanceID
        {
            removeObservationState(for: replacedInstanceID)
        }
        if result.state == .installed {
            rejectedEventCount = 0
        }
        applyHookInstallationResult(result)
        render(reducer.state, at: .now)
        if hookInstallationState == .installed,
            hookRuntimeStatus != .ready
        {
            beginCodexReview(
                reportInstallation: shouldAutoConnectForE2E,
                configurationGeneration: generation
            )
        } else if shouldAutoConnectForE2E, hookInstallationState == .installed {
            let presentation = ConnectionStatusPresentation.make(
                diagnostics: connectionDiagnostics,
                now: .now
            )
            e2eReporter.record("hook_installation", fields: [
                "connectionAction": connectionOverlay?.connectionActionKindForE2E
                    ?? "hidden",
                "connectionStatus": presentation.kind.rawValue,
                "hookInstalled": true,
                "hooksCommandCopied": false,
                "rejectedEventCount": rejectedEventCount,
                "reviewLaunchSucceeded": false,
                "reviewRecoveryGuidanceVisible": connectionOverlay?
                    .reviewRecoveryGuidanceVisibleForE2E ?? false,
                "runtimeStatus": hookRuntimeStatus.rawValue,
            ])
        }
    }

    private func beginCodexReview(
        reportInstallation: Bool = false,
        configurationGeneration: UInt? = nil
    ) {
        guard hookInstallationState == .installed, reviewLaunchState != .opening else {
            return
        }
        let expectedGeneration = configurationGeneration ?? hookConfigurationGeneration
        let hooksCommandCopied = connectionOverlay?.copyHooksCommandAfterInstallation() ?? false
        reviewLaunchState = .opening
        didRefreshRuntimeAfterObservation = false
        render(reducer.state, at: .now)
        Task { [weak self] in
            guard let self else { return }
            let opened = await reviewLauncher.open()
            guard expectedGeneration == hookConfigurationGeneration,
                activeHookMutation == nil
            else {
                discardedHookResultCount += 1
                return
            }
            reviewLaunchState = opened ? .opened : .failed
            render(reducer.state, at: .now)
            startReviewStatusRefreshes()
            if reportInstallation {
                e2eReporter.record("hook_installation", fields: [
                    "connectionAction": connectionOverlay?
                        .connectionActionKindForE2E ?? "hidden",
                    "hookInstalled": true,
                    "hooksCommandCopied": hooksCommandCopied
                        && (connectionOverlay?.hooksCommandCopiedForE2E ?? false),
                    "reviewLaunchSucceeded": opened,
                    "reviewRecoveryGuidanceVisible": connectionOverlay?
                        .reviewRecoveryGuidanceVisibleForE2E ?? false,
                    "runtimeStatus": hookRuntimeStatus.rawValue,
                ])
            }
        }
    }

    private func applyCompletedHookRemoval(
        _ result: CodexHookInstallationResult,
        removedInstanceID: String?
    ) {
        let separateInstanceIDs = Set(confirmationLedger.entries.compactMap { entry in
            entry.instanceID == removedInstanceID ? nil : entry.instanceID
        })
        applyHookInstallationResult(result)
        if hookInstallationState == .notInstalled, let removedInstanceID {
            removeObservationState(for: removedInstanceID)
            lastKnownDefaultHookInstanceID = nil
            if shouldPersistConnectionHistory {
                connectionDefaults.removeObject(forKey: lastKnownDefaultHookInstanceKey)
                synchronizeConnectionDefaultsForE2E()
            }
        }
        render(reducer.state, at: .now)
        let defaultActorsRemaining = removedInstanceID.map { instanceID in
            reducer.state.actors.values.contains {
                $0.integrationInstance == instanceID
            }
        } ?? false
        let separateActorPreserved = !separateInstanceIDs.isEmpty
            && separateInstanceIDs.allSatisfy { instanceID in
                reducer.state.actors.values.contains {
                    $0.integrationInstance == instanceID
                }
            }
        let separateConfirmationPreserved = !separateInstanceIDs.isEmpty
            && separateInstanceIDs.allSatisfy {
                confirmationLedger.confirmation(instanceID: $0) != nil
            }
        let presentation = ConnectionStatusPresentation.make(
            diagnostics: connectionDiagnostics,
            now: .now
        )
        e2eReporter.record("hook_removal", fields: [
            "completionReceiptCount": scene?.presentedCompletionReceiptCountForE2E ?? 0,
            "confirmationCleared": isConnectionConfirmationCleared,
            "connectionActionVisible": connectionOverlay?.isActionVisibleForE2E ?? false,
            "connectionStatus": presentation.kind.rawValue,
            "customActorPreserved": separateActorPreserved,
            "customConfirmationPreserved": separateConfirmationPreserved,
            "defaultActorsRemaining": defaultActorsRemaining,
            "hookInstalled": hookInstallationState == .installed,
            "hookState": hookStateLabel,
            "liveActorCount": reducer.state.liveActorCount,
            "managedHookPresent": managedHookPresent,
        ])
    }

    private func refreshHookStatus(
        openOnboarding: Bool,
        preserveVisibleState: Bool = false
    ) {
        if activeHookMutation != nil || pendingHookMutation != nil {
            queueHookStatusRefresh(
                openOnboarding: openOnboarding,
                preserveVisibleState: preserveVisibleState
            )
            return
        }
        if hookStatusRefreshInFlight {
            queueHookStatusRefresh(
                openOnboarding: openOnboarding,
                preserveVisibleState: preserveVisibleState
            )
            return
        }
        let expectedGeneration = hookConfigurationGeneration
        hookStatusRefreshInFlight = true
        if !preserveVisibleState {
            hookInstallationState = .checking
            hookRuntimeStatus = .checking
            runtimeProblemEvents = []
            otherPendingHookCount = nil
            render(reducer.state, at: .now)
        }
        Task { [weak self] in
            guard let self else { return }
            let result = await hookInstaller.status()
            hookStatusRefreshInFlight = false
            guard expectedGeneration == hookConfigurationGeneration,
                activeHookMutation == nil,
                pendingHookMutation == nil
            else {
                discardedHookResultCount += 1
                queueHookStatusRefresh(
                    openOnboarding: openOnboarding,
                    preserveVisibleState: true
                )
                drainPendingHookStatusRefreshIfPossible()
                return
            }
            let resultIsUnavailable: Bool
            if case .unavailable = result.state {
                resultIsUnavailable = true
            } else {
                resultIsUnavailable = false
            }
            let keepVisibleReviewState = preserveVisibleState
                && resultIsUnavailable
                && hookInstallationState == .installed
                && hookRuntimeStatus != .ready
            if !keepVisibleReviewState {
                applyHookInstallationResult(result)
            } else {
                startReviewStatusRefreshesIfNeeded()
            }
            reconcilePersistedConfirmation(with: result)
            render(reducer.state, at: .now)
            autoShowStateLegendHelpForE2EIfNeeded()
            let diagnostics = connectionDiagnostics
            let needsOnboarding = diagnostics.needsOnboarding
            let presentation = ConnectionStatusPresentation.make(
                diagnostics: diagnostics,
                now: .now
            )
            e2eReporter.record("hook_status", fields: [
                "connectionAction": connectionOverlay?.connectionActionKindForE2E
                    ?? "hidden",
                "connectionActionVisible": connectionOverlay?.isActionVisibleForE2E ?? false,
                "connectionGuidanceVisible": connectionOverlay?.isGuidanceVisible ?? false,
                "connectionGuidanceLayoutValid": connectionOverlay?
                    .isGuidanceLayoutValidForE2E ?? false,
                "connectionGuidanceScrollable": connectionOverlay?
                    .isGuidanceScrollableForE2E ?? false,
                "hookInstalled": hookInstallationState == .installed,
                "hookState": hookStateLabel,
                "connectionStatus": presentation.kind.rawValue,
                "connectionStatusConsistent": statusController?
                    .matchesConnectionLabelForE2E(presentation.menuLabel) == true
                    && connectionOverlay?.matchesConnectionPresentationForE2E(
                        presentation
                    ) == true,
                "inlineHooksPresent": inlineHooksPresent,
                "inlineAdvisory": connectionOverlay?.inlineAdvisoryVisibleForE2E
                    ?? false,
                "currentHookConfirmed": diagnostics.currentHookConfirmedAt != nil,
                "managedHookPresent": managedHookPresent,
                "onboardingNeeded": needsOnboarding,
                "rejectedEventCount": rejectedEventCount,
                "runtimeStatus": hookRuntimeStatus.rawValue,
                "otherPendingHookCount": otherPendingHookCount ?? -1,
                "reviewRecoveryGuidanceVisible": connectionOverlay?
                    .reviewRecoveryGuidanceVisibleForE2E ?? false,
                "separateConnectionConfirmed": diagnostics
                    .hasSeparateConnectionConfirmation,
                "separateForgetVisible": connectionOverlay?
                    .isSeparateForgetVisibleForE2E ?? false,
                "staleHookResultsDiscarded": discardedHookResultCount,
            ])
            autoRemoveCurrentHookForE2EIfNeeded()
            if
                shouldAutoForgetForE2E,
                !didAutoForgetForE2E,
                lastEventAt != nil || previouslyConfirmedAt != nil
            {
                didAutoForgetForE2E = true
                connectionOverlay?.performSecondaryActionForE2E()
            }
            if openOnboarding,
                needsOnboarding || shouldOpenAfterHookStatusForE2E
            {
                statusController?.presentMeongSpace()
            }
            if
                shouldAutoConnectForE2E,
                !didAutoConnectForE2E,
                hookInstallationState == .notInstalled
            {
                didAutoConnectForE2E = true
                connectionOverlay?.performPrimaryActionForE2E()
            }
            drainPendingHookStatusRefreshIfPossible()
        }
    }

    private func queueHookStatusRefresh(
        openOnboarding: Bool,
        preserveVisibleState: Bool
    ) {
        hookStatusRefreshPending = true
        pendingHookStatusOpenOnboarding = pendingHookStatusOpenOnboarding
            || openOnboarding
        pendingHookStatusPreservesVisibleState = pendingHookStatusPreservesVisibleState
            || preserveVisibleState
    }

    private func drainPendingHookStatusRefreshIfPossible() {
        guard hookStatusRefreshPending,
            !hookStatusRefreshInFlight,
            activeHookMutation == nil,
            pendingHookMutation == nil
        else { return }
        let openOnboarding = pendingHookStatusOpenOnboarding
        let preserveVisibleState = pendingHookStatusPreservesVisibleState
        hookStatusRefreshPending = false
        pendingHookStatusOpenOnboarding = false
        pendingHookStatusPreservesVisibleState = false
        refreshHookStatus(
            openOnboarding: openOnboarding,
            preserveVisibleState: preserveVisibleState
        )
    }

    private func refreshHookStatusOnPopoverOpen() {
        guard !isDemo else { return }
        if hookInstallationState == .installed,
            (hookRuntimeStatus == .reviewRequired || hookRuntimeStatus == .disabled)
        {
            reviewStatusRefreshWorkItem?.cancel()
            reviewStatusRefreshWorkItem = nil
            reviewStatusRefreshAttempt = 0
        }
        guard ConnectionStatusRefreshPolicy.shouldRefreshOnPopoverOpen(
            runtimeIsReady: hookInstallationState == .installed
                && hookRuntimeStatus == .ready,
            lastCompletedAt: lastCompletedHookStatusRefreshAt,
            now: .now
        ) else { return }
        refreshHookStatus(openOnboarding: false, preserveVisibleState: true)
    }

    private func applyHookInstallationResult(_ result: CodexHookInstallationResult) {
        lastCompletedHookStatusRefreshAt = .now
        hookInstallationState = result.state
        inlineHooksPresent = result.inlineHooksPresent
        managedHookPresent = result.managedHookPresent
        currentHookDefinitionID = result.definitionID
        currentHookInstanceID = result.instanceID
        if result.managedHookPresent, let instanceID = result.instanceID {
            lastKnownDefaultHookInstanceID = instanceID
            if shouldPersistConnectionHistory {
                connectionDefaults.set(instanceID, forKey: lastKnownDefaultHookInstanceKey)
                synchronizeConnectionDefaultsForE2E()
            }
        }
        hookRuntimeStatus = result.runtimeStatus
        runtimeProblemEvents = result.runtimeProblemEvents
        otherPendingHookCount = result.otherPendingHookCount
        if result.state != .installed || result.runtimeStatus == .ready {
            reviewLaunchState = .idle
            reviewStatusRefreshWorkItem?.cancel()
            reviewStatusRefreshWorkItem = nil
            reviewStatusRefreshAttempt = 0
        } else if result.runtimeStatus == .reviewRequired
            || result.runtimeStatus == .disabled
            || reviewStatusRefreshAttempt > 0
        {
            startReviewStatusRefreshesIfNeeded()
        }
    }

    private func startReviewStatusRefreshes() {
        reviewStatusRefreshWorkItem?.cancel()
        reviewStatusRefreshWorkItem = nil
        reviewStatusRefreshAttempt = 0
        scheduleNextReviewStatusRefresh()
    }

    private func startReviewStatusRefreshesIfNeeded() {
        guard reviewStatusRefreshWorkItem == nil,
            !hookStatusRefreshInFlight,
            !hookStatusRefreshPending
        else { return }
        scheduleNextReviewStatusRefresh()
    }

    private func scheduleNextReviewStatusRefresh() {
        guard hookInstallationState == .installed,
            hookRuntimeStatus != .ready,
            reviewStatusRefreshAttempt < ConnectionReviewRefreshPolicy.maximumAttemptCount
        else { return }
        let delay: TimeInterval?
        if let e2eInterval = reviewStatusRefreshIntervalForE2E {
            delay = e2eInterval
        } else {
            delay = ConnectionReviewRefreshPolicy.delay(
                afterCompletedAttempts: reviewStatusRefreshAttempt
            )
        }
        guard let delay else { return }
        reviewStatusRefreshAttempt += 1
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            reviewStatusRefreshWorkItem = nil
            guard hookInstallationState == .installed, hookRuntimeStatus != .ready else {
                return
            }
            refreshHookStatus(openOnboarding: false, preserveVisibleState: true)
        }
        reviewStatusRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func clearAllConnectionHistory() {
        lastEventAt = nil
        previouslyConfirmedAt = nil
        lastObservedIntegrationVersion = nil
        lastObservedIntegrationInstance = nil
        confirmationLedger.removeAll()
        observedInstancesThisRun.removeAll(keepingCapacity: true)
        pendingConfirmationAt = nil
        pendingConfirmationDefinitionID = nil
        pendingConfirmationInstanceID = nil
        didResolvePersistedConfirmation = true
        rejectedEventCount = 0
        reducer = WorldReducer()
        scene?.clearCompletionReceipts()
        statusController?.acknowledgeWorkEnd()
        didScheduleCompletionReceiptOpenForE2E = false
        try? worldCheckpointStore.clear()
        if shouldPersistConnectionHistory {
            connectionDefaults.removeObject(forKey: lastConfirmedEventKey)
            connectionDefaults.removeObject(forKey: lastConfirmedDefinitionKey)
            connectionDefaults.removeObject(forKey: lastConfirmedInstanceKey)
            connectionDefaults.removeObject(forKey: confirmationLedgerKey)
            synchronizeConnectionDefaultsForE2E()
        }
        scheduleNextTick()
    }

    private func removeObservationState(for integrationInstance: String) {
        guard !integrationInstance.isEmpty else { return }
        let removedActorIDs = reducer.removeActors(
            integrationInstance: integrationInstance
        )
        confirmationLedger.remove(instanceID: integrationInstance)
        observedInstancesThisRun.remove(integrationInstance)
        if lastObservedIntegrationInstance == integrationInstance {
            applyLatestConfirmation()
        }
        _ = scene?.removeCompletionReceipts(for: removedActorIDs)
        let remainingReceipts = scene?.removeCompletionReceipts(
            integrationInstance: integrationInstance
        ) ?? 0
        statusController?.reconcileUnseenWorkEndCount(remainingReceipts)
        persistWorldState()
        if shouldPersistConnectionHistory {
            persistConnectionHistory()
        }
        scheduleNextTick()
    }

    private func loadConnectionHistory() {
        if let data = connectionDefaults.data(forKey: confirmationLedgerKey),
            let ledger = try? JSONDecoder().decode(
                ConnectionConfirmationLedger.self,
                from: data
            ),
            !ledger.entries.isEmpty
        {
            confirmationLedger = ledger
            didResolvePersistedConfirmation = true
            applyLatestConfirmation()
            return
        }
        pendingConfirmationAt = connectionDefaults.object(
            forKey: lastConfirmedEventKey
        ) as? Date
        pendingConfirmationDefinitionID = connectionDefaults.string(
            forKey: lastConfirmedDefinitionKey
        )
        pendingConfirmationInstanceID = connectionDefaults.string(
            forKey: lastConfirmedInstanceKey
        )
    }

    private func applyLatestConfirmation() {
        guard let latest = confirmationLedger.latest else {
            lastEventAt = nil
            previouslyConfirmedAt = nil
            lastObservedIntegrationVersion = nil
            lastObservedIntegrationInstance = nil
            return
        }
        lastEventAt = observedInstancesThisRun.contains(latest.instanceID)
            ? latest.confirmedAt
            : nil
        previouslyConfirmedAt = latest.confirmedAt
        lastObservedIntegrationVersion = latest.definitionID
        lastObservedIntegrationInstance = latest.instanceID
    }

    private func persistConnectionHistory() {
        if let data = try? JSONEncoder().encode(confirmationLedger),
            !confirmationLedger.entries.isEmpty
        {
            connectionDefaults.set(data, forKey: confirmationLedgerKey)
        } else {
            connectionDefaults.removeObject(forKey: confirmationLedgerKey)
        }
        if let date = lastEventAt ?? previouslyConfirmedAt {
            connectionDefaults.set(date, forKey: lastConfirmedEventKey)
        } else {
            connectionDefaults.removeObject(forKey: lastConfirmedEventKey)
        }
        if let definitionID = lastObservedIntegrationVersion {
            connectionDefaults.set(definitionID, forKey: lastConfirmedDefinitionKey)
        } else {
            connectionDefaults.removeObject(forKey: lastConfirmedDefinitionKey)
        }
        if let instanceID = lastObservedIntegrationInstance {
            connectionDefaults.set(instanceID, forKey: lastConfirmedInstanceKey)
        } else {
            connectionDefaults.removeObject(forKey: lastConfirmedInstanceKey)
        }
        synchronizeConnectionDefaultsForE2E()
    }

    private func forgetConnectionHistory() {
        let separateInstanceIDs = confirmationLedger.entries.compactMap { entry in
            entry.instanceID == defaultHookReferenceID ? nil : entry.instanceID
        }
        if defaultHookReferenceID != nil, !separateInstanceIDs.isEmpty {
            separateInstanceIDs.forEach(removeObservationState)
        } else {
            clearAllConnectionHistory()
        }
        render(reducer.state, at: .now)
        if connectionDiagnostics.needsOnboarding {
            connectionOverlay?.showGuidance()
        }
        e2eReporter.record("connection_forget", fields: [
            "confirmationCleared": isConnectionConfirmationCleared,
            "connectionGuidanceVisible": connectionOverlay?.isGuidanceVisible ?? false,
            "connectionStatus": ConnectionStatusPresentation.make(
                diagnostics: connectionDiagnostics,
                now: .now
            ).kind.rawValue,
            "currentHookConfirmed": connectionDiagnostics.currentHookConfirmedAt != nil,
            "liveActorCount": reducer.state.liveActorCount,
            "separateConnectionConfirmed": connectionDiagnostics
                .hasSeparateConnectionConfirmation,
            "separateForgetVisible": connectionOverlay?
                .isSeparateForgetVisibleForE2E ?? false,
        ])
    }

    private func reconcilePersistedConfirmation(
        with result: CodexHookInstallationResult
    ) {
        guard !didResolvePersistedConfirmation else {
            return
        }
        if lastEventAt != nil {
            didResolvePersistedConfirmation = true
            pendingConfirmationAt = nil
            pendingConfirmationDefinitionID = nil
            pendingConfirmationInstanceID = nil
            return
        }
        if shouldBindE2EConfirmationToCurrentDefinition,
            result.definitionID == nil || result.instanceID == nil
        {
            return
        }
        didResolvePersistedConfirmation = true
        let storedDefinitionID = shouldBindE2EConfirmationToCurrentDefinition
            ? result.definitionID
            : pendingConfirmationDefinitionID
        let storedInstanceID = shouldBindE2EConfirmationToCurrentDefinition
            ? result.instanceID
            : pendingConfirmationInstanceID
        if let date = pendingConfirmationAt, let storedInstanceID {
            confirmationLedger.record(
                instanceID: storedInstanceID,
                definitionID: storedDefinitionID,
                at: date
            )
            applyLatestConfirmation()
            if shouldPersistWorldState {
                restorePersistedWorld(at: .now)
            }
        } else {
            previouslyConfirmedAt = nil
        }
        pendingConfirmationAt = nil
        pendingConfirmationDefinitionID = nil
        pendingConfirmationInstanceID = nil
        if shouldPersistConnectionHistory {
            persistConnectionHistory()
        }
        scheduleNextTick()
    }

    private var hookProblemOverridesHistory: Bool {
        switch hookInstallationState {
        case .checking, .installed:
            return false
        case .notInstalled, .needsRepair, .invalidConfiguration, .hooksDisabled,
            .managedHooksOnly, .newerVersion, .unavailable:
            if defaultHookHistoryConfirmation != nil {
                return true
            }
            // Only the legacy single-confirmation format needs the old
            // latest-observation fallback. Ledger entries already identify
            // default and separate connections independently.
            guard confirmationLedger.entries.isEmpty,
                lastEventAt != nil || previouslyConfirmedAt != nil
            else { return false }
            if
                let observedInstance = lastObservedIntegrationInstance,
                let currentInstance = defaultHookReferenceID
            {
                return observedInstance == currentInstance
            }
            // A pre-companion installation can have a real managed hook but no
            // instance id. Surface its repair state without deleting a possibly
            // separate custom-home confirmation.
            return managedHookPresent && currentHookInstanceID == nil
        }
    }

    private var defaultHookHistoryConfirmation: ConnectionConfirmation? {
        defaultHookReferenceID.flatMap {
            confirmationLedger.confirmation(instanceID: $0)
        }
    }

    private func connectionLabel(at now: Date) -> String {
        if isDemo { return L10n.text("데모 fixture", "Demo fixture") }
        return ConnectionStatusPresentation.make(
            diagnostics: connectionDiagnostics,
            now: now
        ).menuLabel
    }

    private var hookStateLabel: String {
        switch hookInstallationState {
        case .checking: "checking"
        case .notInstalled: "notInstalled"
        case .installed: "installed"
        case .needsRepair: "needsRepair"
        case .invalidConfiguration: "invalidConfiguration"
        case .hooksDisabled: "hooksDisabled"
        case .managedHooksOnly: "managedHooksOnly"
        case .newerVersion: "newerVersion"
        case .unavailable: "unavailable"
        }
    }

    private var reviewStatusRefreshIntervalForE2E: TimeInterval? {
        guard e2eReporter.isEnabled,
            let value = ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_REVIEW_REFRESH_INTERVAL"
            ],
            let interval = TimeInterval(value),
            interval.isFinite,
            interval >= 0.02,
            interval <= 2
        else { return nil }
        return interval
    }

    private func scheduleNextTick() {
        ticker?.invalidate()
        let now = Date.now
        let expiryDelay = reducer.nextExpiryDate().map { max(0.05, $0.timeIntervalSince(now)) }
        let connectionDelay = lastEventAt.map {
            L10n.relativeAgeRefreshDelay(from: $0, to: now)
        }
        guard let delay = [expiryDelay, connectionDelay].compactMap({ $0 }).min() else { return }
        ticker = Timer.scheduledTimer(
            timeInterval: delay,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: false
        )
    }

    private var receiverReady: Bool {
        socketServer?.isHealthy == true
    }

    private var shouldPersistConnectionHistory: Bool {
        !isDemo && (!e2eReporter.isEnabled || e2eDefaultsSuiteName != nil)
    }

    private var hasSeenStateLegend: Bool {
        stateLegendSeenThisRun
            || (shouldPersistConnectionHistory
                && connectionDefaults.integer(forKey: stateLegendVersionKey)
                    >= Self.stateLegendVersion)
    }

    private func queueStateLegendAfterAcceptedObservation() {
        guard !hasSeenStateLegend, !stateLegendPending, !stateLegendInFlight else { return }
        stateLegendPending = true
        presentPendingStateLegendIfPossible()
        if popover?.isShown != true {
            autoReopenStateLegendForE2EIfNeeded()
        }
    }

    private func reconcileStateLegendPresentation() {
        guard
            stateLegendInFlight,
            connectionOverlay?.isStateLegendVisible != true
        else { return }
        stateLegendInFlight = false
        stateLegendPending = !hasSeenStateLegend
    }

    private func stateLegendWasCancelled() {
        stateLegendInFlight = false
        stateLegendPending = !hasSeenStateLegend
    }

    private func cancelStateLegendForRetry() {
        guard stateLegendInFlight else { return }
        connectionOverlay?.cancelStateLegend()
        // Keep the state correct even if the overlay has already hidden itself
        // and therefore has no cancellation callback left to send.
        stateLegendInFlight = false
        stateLegendPending = !hasSeenStateLegend
    }

    private func presentPendingStateLegendIfPossible() {
        guard
            stateLegendPending,
            !stateLegendInFlight,
            !hasSeenStateLegend,
            popoverVisibility == .open,
            let connectionOverlay,
            !connectionOverlay.isGuidanceVisible
        else { return }

        stateLegendPending = false
        presentStateLegend(manual: false)
    }

    private func showStateLegendManually() {
        guard popoverVisibility == .open, let connectionOverlay else { return }
        connectionOverlay.cancelStateLegend()
        stateLegendInFlight = false
        stateLegendPending = false
        presentStateLegend(manual: true)
    }

    private func presentStateLegend(manual: Bool) {
        guard
            popoverVisibility == .open,
            let connectionOverlay,
            !connectionOverlay.isGuidanceVisible
        else { return }

        let wasPreviouslySeen = hasSeenStateLegend
        let shown = connectionOverlay.presentStateLegend(
            duration: stateLegendPresentationDuration(manual: manual),
            reduceMotion: reduceMotionEnabled,
            scope: manual ? .allStates : .essentials
        ) { [weak self] in
            guard let self else { return }
            stateLegendInFlight = false
            stateLegendPending = false
            if !manual {
                stateLegendSeenThisRun = true
                if shouldPersistConnectionHistory {
                    connectionDefaults.set(
                        Self.stateLegendVersion,
                        forKey: stateLegendVersionKey
                    )
                    synchronizeConnectionDefaultsForE2E()
                }
            }
            let popoverBehaviorRestored = restoreStateLegendRetryPopoverForE2EIfNeeded()
            e2eReporter.record("state_legend_completed", fields: [
                "popoverBehaviorRestored": popoverBehaviorRestored,
                "stateLegendAccessible": connectionOverlay.isStateLegendAccessible,
                "stateLegendHelpIcon": connectionOverlay.isStateLegendHelpIconForE2E,
                "stateLegendManual": manual,
                "stateLegendScope": connectionOverlay.stateLegendScopeForE2E,
                "stateLegendReduceMotionStatic": connectionOverlay
                    .isReduceMotionLegendStaticForE2E,
                "stateLegendPreviouslySeen": wasPreviouslySeen,
                "stateLegendVersion": Self.stateLegendVersion,
                "stateLegendVisible": connectionOverlay.isStateLegendVisible,
            ])
        }
        guard shown else { return }
        stateLegendInFlight = true
        e2eReporter.record("state_legend_shown", fields: [
            "stateLegendAccessible": connectionOverlay.isStateLegendAccessible,
            "stateLegendHelpIcon": connectionOverlay.isStateLegendHelpIconForE2E,
            "stateLegendManual": manual,
            "stateLegendScope": connectionOverlay.stateLegendScopeForE2E,
            "stateLegendReduceMotionStatic": connectionOverlay
                .isReduceMotionLegendStaticForE2E,
            "stateLegendPreviouslySeen": wasPreviouslySeen,
            "stateLegendVersion": Self.stateLegendVersion,
            "stateLegendVisible": connectionOverlay.isStateLegendVisible,
        ])
        autoCloseStateLegendForE2EIfNeeded(manual: manual)
    }

    private func stateLegendPresentationDuration(manual: Bool) -> TimeInterval {
        guard e2eReporter.isEnabled else { return manual ? 12 : 4 }
        if
            let rawValue = ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_STATE_LEGEND_DURATION"
            ],
            let duration = TimeInterval(rawValue),
            duration.isFinite,
            duration >= 0.05,
            duration <= 10
        {
            return duration
        }
        return 0.25
    }

    private var shouldAutoConnectForE2E: Bool {
        ProcessInfo.processInfo.environment["AGENT_MEONG_E2E_AUTO_CONNECT"] == "1"
    }

    private func autoCloseStateLegendForE2EIfNeeded(manual: Bool) {
        guard
            e2eReporter.isEnabled,
            !manual,
            !didAutoCloseStateLegendForE2E,
            ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_AUTO_CLOSE_STATE_LEGEND"
            ] == "1"
        else { return }

        didAutoCloseStateLegendForE2E = true
        // The first presentation may itself have been opened by the E2E retry
        // helper. Re-arm that helper so this forced cancellation always gets
        // exactly one fresh presentation.
        didAutoReopenStateLegendForE2E = false
        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                popoverVisibility == .open,
                stateLegendInFlight
            else { return }
            popover?.performClose(nil)
        }
    }

    private var reduceMotionEnabled: Bool {
        if e2eReporter.isEnabled,
            ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_REDUCE_MOTION"
            ] == "1"
        {
            return true
        }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var shouldAutoConnectDuringInitialStatusForE2E: Bool {
        e2eReporter.isEnabled
            && shouldAutoConnectForE2E
            && ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_AUTO_CONNECT_DURING_STATUS"
            ] == "1"
    }

    private func autoShowStateLegendHelpForE2EIfNeeded() {
        guard
            e2eReporter.isEnabled,
            ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_AUTO_SHOW_STATE_LEGEND_HELP"
            ] == "1",
            !didAutoShowStateLegendHelpForE2E,
            popoverVisibility == .open,
            let connectionOverlay,
            !connectionOverlay.isGuidanceVisible
        else { return }
        didAutoShowStateLegendHelpForE2E = true
        connectionOverlay.performStateLegendHelpForE2E()
    }

    private var shouldOpenAfterHookStatusForE2E: Bool {
        e2eReporter.isEnabled
            && ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_OPEN_AFTER_HOOK_STATUS"
            ] == "1"
    }

    private func presentInitialConnectionProgress() {
        guard popover?.isShown != true, let statusController else { return }
        statusController.presentMeongSpace()
    }

    private var shouldAutoForgetForE2E: Bool {
        e2eReporter.isEnabled
            && ProcessInfo.processInfo.environment["AGENT_MEONG_E2E_AUTO_FORGET"] == "1"
    }

    private var shouldAutoRemoveHookForE2E: Bool {
        e2eReporter.isEnabled
            && ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_AUTO_REMOVE_HOOK"
            ] == "1"
    }

    private func autoOpenCompletionReceiptsForE2EIfNeeded() {
        guard
            e2eReporter.isEnabled,
            ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_AUTO_OPEN_COMPLETION_RECEIPTS"
            ] == "1",
            !didScheduleCompletionReceiptOpenForE2E,
            popover?.isShown != true,
            scene?.pendingCompletionReceiptCount ?? 0 > 0
        else { return }
        didScheduleCompletionReceiptOpenForE2E = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            didScheduleCompletionReceiptOpenForE2E = false
            guard
                popover?.isShown != true,
                scene?.pendingCompletionReceiptCount ?? 0 > 0,
                let positioningView = statusController?.positioningViewForPresentation
            else { return }
            showMeongSpace(relativeTo: positioningView)
        }
    }

    private func autoReopenStateLegendForE2EIfNeeded() {
        guard
            e2eReporter.isEnabled,
            ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_AUTO_REOPEN_STATE_LEGEND"
            ] == "1",
            !didAutoReopenStateLegendForE2E,
            stateLegendPending,
            !hasSeenStateLegend
        else { return }
        didAutoReopenStateLegendForE2E = true
        // Let the close transition settle before the test reopens the popover.
        // Reopening inside the same transition can receive a delayed callback
        // and close the second legend before its timer completes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard
                let self,
                popover?.isShown != true,
                stateLegendPending,
                !hasSeenStateLegend,
                let positioningView = statusController?.positioningViewForPresentation
            else { return }
            NSApp.activate(ignoringOtherApps: true)
            isHoldingStateLegendRetryPopoverForE2E = true
            popover?.behavior = .applicationDefined
            showMeongSpace(relativeTo: positioningView)
        }
    }

    private func restoreStateLegendRetryPopoverForE2EIfNeeded() -> Bool {
        guard isHoldingStateLegendRetryPopoverForE2E else {
            return popover?.behavior == .transient
        }
        isHoldingStateLegendRetryPopoverForE2E = false
        popover?.behavior = .transient
        return popover?.behavior == .transient
    }

    private func autoRemoveCurrentHookForE2EIfNeeded() {
        guard
            shouldAutoRemoveHookForE2E,
            !didAutoRemoveHookForE2E,
            managedHookPresent,
            let currentInstanceID = currentHookInstanceID,
            observedInstancesThisRun.contains(currentInstanceID),
            observedInstancesThisRun.contains(where: { $0 != currentInstanceID })
        else { return }
        if ProcessInfo.processInfo.environment[
            "AGENT_MEONG_E2E_REMOVE_AFTER_PRESENTED_RECEIPTS"
        ] == "1" {
            guard
                let scene,
                scene.pendingCompletionReceiptCount >= 2,
                scene.presentCompletionReceipts() >= 2
            else { return }
            // Exercise the real post-popover state: receipt data has been
            // acknowledged, while its short-lived visual nodes remain.
            scene.acknowledgeCompletionReceipts()
        }
        if ProcessInfo.processInfo.environment[
            "AGENT_MEONG_E2E_EXPIRE_ACTORS_BEFORE_REMOVAL"
        ] == "1" {
            // Keep the selective-removal check deterministic: terminal actors
            // normally expire after eight seconds, while their unseen receipt
            // must still retain enough ownership to be removed with its hook.
            let expiredState = reducer.expire(
                at: Date.now.addingTimeInterval(9)
            )
            _ = render(expiredState, at: .now)
        }
        didAutoRemoveHookForE2E = true
        connectionOverlay?.performHookRemovalForE2E()
    }

    private func autoForgetSeparateConnectionForE2EIfNeeded() {
        guard
            e2eReporter.isEnabled,
            ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_AUTO_FORGET_SEPARATE"
            ] == "1",
            !didAutoForgetForE2E,
            connectionDiagnostics.currentHookConfirmedAt != nil,
            connectionDiagnostics.hasSeparateConnectionConfirmation,
            connectionOverlay?.isSeparateForgetVisibleForE2E == true
        else { return }
        didAutoForgetForE2E = true
        connectionOverlay?.performSecondaryActionForE2E()
    }

    private var e2eDefaultsSuiteName: String? {
        guard e2eReporter.isEnabled else { return nil }
        let value = ProcessInfo.processInfo.environment["AGENT_MEONG_E2E_DEFAULTS_SUITE"]
        return value?.isEmpty == false ? value : nil
    }

    private var isConnectionConfirmationCleared: Bool {
        let memoryCleared = lastEventAt == nil
            && previouslyConfirmedAt == nil
            && lastObservedIntegrationVersion == nil
            && lastObservedIntegrationInstance == nil
            && confirmationLedger.entries.isEmpty
        guard shouldPersistConnectionHistory else { return memoryCleared }
        return memoryCleared
            && connectionDefaults.object(forKey: lastConfirmedEventKey) == nil
            && connectionDefaults.object(forKey: lastConfirmedDefinitionKey) == nil
            && connectionDefaults.object(forKey: lastConfirmedInstanceKey) == nil
            && connectionDefaults.object(forKey: confirmationLedgerKey) == nil
    }

    private func synchronizeConnectionDefaultsForE2E() {
        guard e2eDefaultsSuiteName != nil else { return }
        connectionDefaults.synchronize()
    }

    private var shouldPersistWorldState: Bool {
        shouldPersistConnectionHistory
            && ProcessInfo.processInfo.environment["AGENT_MEONG_SOCKET"] == nil
    }

    private var worldCheckpointStore: WorldCheckpointStore {
        let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentMeong", isDirectory: true)
        return WorldCheckpointStore(
            fileURL: supportDirectory.appendingPathComponent("world-checkpoint-v1.json")
        )
    }

    private func sceneAccessibilitySummary(
        _ state: WorldState,
        completionReceiptCount: Int
    ) -> String {
        let counts: [(Int, String, String)] = [
            (state.quietActorCount, "조용함", "quiet"),
            (state.activeActorCount, "활동 중", "active"),
            (state.attentionActorCount, "확인 필요", "need attention"),
            (state.uncertainActorCount, "불확실", "uncertain"),
            (state.finishedActorCount, "종료", "finished"),
            (state.completedActorCount, "완료", "completed"),
            (state.cancelledActorCount, "취소", "cancelled"),
            (state.failedActorCount, "실패", "failed"),
        ]
        let visibleCounts = counts.filter { $0.0 > 0 }
        let details = visibleCounts.isEmpty
            ? L10n.text("관찰된 에이전트 없음", "No observed agents")
            : visibleCounts.map { count, korean, english in
                L10n.text("\(korean) \(count)개", "\(count) \(english)")
            }.joined(separator: ", ")
        let receipts = completionReceiptCount > 0
            ? L10n.text(
                ", 최근 종료 흔적이 남은 에이전트 가족 \(completionReceiptCount)개",
                ", \(completionReceiptCount) recent agent \(completionReceiptCount == 1 ? "family has" : "families have") unseen end receipts"
            )
            : ""
        return "\(L10n.stateLabel(state.aggregateState)). \(details)\(receipts)"
    }

    private var stateGrammarAccessibilityHelp: String {
        L10n.text(
            "움직임은 활동 중이며 동작 줄이기에서는 꺾쇠 표식으로 대신합니다. 고리는 확인 필요, 분절 고리는 불확실, 열린 호는 종료, 이중 후광은 완료, 가로 막대는 취소, 마름모는 실패, 바깥으로 번지는 파동은 방금 관찰된 턴 종료를 뜻합니다. 부모와 자식은 같은 색 계열을 공유하지만 색은 고유 ID가 아닙니다.",
            "Movement means active and becomes a chevron marker with Reduce Motion. A ring means needs attention, a segmented ring means uncertain, an open arc means finished, a double halo means completed, a horizontal bar means cancelled, a diamond means failed, and an outward ripple means a newly observed turn end. Related parents and children share a color family, but color is not a unique ID."
        )
    }

    private func completionReceiptAccessibilityAnnouncement(_ count: Int) -> String {
        L10n.text(
            "최근 종료 흔적이 남은 에이전트 가족 \(count)개를 장면에 표시합니다.",
            "Showing end receipts for \(count) recent agent \(count == 1 ? "family" : "families") in the scene."
        )
    }

    @objc private func accessibilityDisplayOptionsChanged() {
        render(reducer.state, at: .now)
    }

    private func toggleMeongSpace(relativeTo positioningView: NSView) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self, weak positioningView] in
            guard let positioningView else { return }
            self?.showMeongSpaceWhenAnchorIsReady(relativeTo: positioningView)
        }
    }

    private func showMeongSpaceWhenAnchorIsReady(
        relativeTo positioningView: NSView,
        attemptsRemaining: Int = 60
    ) {
        guard let popover, !popover.isShown else { return }
        if isPresentationAnchorReady(positioningView) {
            showMeongSpace(relativeTo: positioningView)
            return
        }
        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak positioningView] in
            guard let self, let positioningView else { return }
            showMeongSpaceWhenAnchorIsReady(
                relativeTo: positioningView,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private func isPresentationAnchorReady(_ positioningView: NSView) -> Bool {
        guard
            !positioningView.bounds.isEmpty,
            let anchorWindow = positioningView.window,
            let anchorScreen = anchorWindow.screen
        else { return false }

        let anchorFrame = anchorWindow.convertToScreen(
            positioningView.convert(positioningView.bounds, to: nil)
        )
        return PopoverAnchorReadiness.isReady(
            anchorFrame: anchorFrame,
            screenFrame: anchorScreen.frame
        )
    }

    private func showMeongSpace(relativeTo positioningView: NSView) {
        guard let popover, !popover.isShown else { return }
        render(reducer.state, at: .now)
        scene?.isPaused = false
        popoverPositioningView = positioningView
        popoverVisibility = .opening
        popover.show(
            relativeTo: positioningView.bounds,
            of: positioningView,
            preferredEdge: .minY
        )
        popover.contentViewController?.view.window?.makeKey()
        presentPendingStateLegendIfPossible()
        didReportActivePopover = false
        NSApp.activate(ignoringOtherApps: true)
        reportActivePopoverIfNeeded()
    }

    private func presentCompletionReceiptsAfterPopoverDidShow() {
        let completionReceiptCount = scene?.presentCompletionReceipts() ?? 0
        statusController?.acknowledgeWorkEnd()
        guard completionReceiptCount > 0 else { return }

        presentedCompletionReceiptAccessibilityCount = completionReceiptCount
        let accessibilitySummary = sceneAccessibilitySummary(
            reducer.state,
            completionReceiptCount: completionReceiptCount
        )
        sceneView?.setAccessibilityValue(accessibilitySummary)
        if let sceneView {
            NSAccessibility.post(
                element: sceneView,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: completionReceiptAccessibilityAnnouncement(
                        completionReceiptCount
                    ),
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
        let receiptsAccessible = sceneView?.isAccessibilityElement() == true
            && sceneView?.accessibilityRole() == .group
            && sceneView?.accessibilityValue() as? String == accessibilitySummary
        scene?.acknowledgeCompletionReceipts()
        let receiptsAcknowledged = scene?.pendingCompletionReceiptCount == 0
        e2eReporter.record("completion_receipts_presented", fields: [
            "completionReceiptCount": completionReceiptCount,
            "completionReceiptsAccessible": receiptsAccessible,
            "completionReceiptsAcknowledged": receiptsAcknowledged,
        ])
        guard e2eReporter.isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, popoverVisibility == .open else { return }
            let accessibilitySummary = sceneAccessibilitySummary(
                reducer.state,
                completionReceiptCount: completionReceiptCount
            )
            e2eReporter.record("completion_receipts_accessibility_retained", fields: [
                "completionReceiptCount": presentedCompletionReceiptAccessibilityCount,
                "completionReceiptsAccessible": sceneView?
                    .accessibilityValue() as? String == accessibilitySummary,
            ])
            if ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_CLOSE_AFTER_RECEIPT_RETENTION"
            ] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.popover?.performClose(nil)
                }
            }
        }
    }

    private func reportPopoverGeometry(relativeTo positioningView: NSView) {
        guard
            e2eReporter.isEnabled,
            popover?.isShown == true,
            let contentView = popover?.contentViewController?.view,
            let popoverWindow = contentView.window,
            let anchorWindow = positioningView.window,
            let anchorScreen = anchorWindow.screen,
            let popoverScreen = popoverWindow.screen
        else { return }

        let anchorFrame = anchorWindow.convertToScreen(
            positioningView.convert(positioningView.bounds, to: nil)
        )
        let popoverFrame = popoverWindow.frame
        let contentFrame = popoverWindow.convertToScreen(
            contentView.convert(contentView.bounds, to: nil)
        )
        let expandedVisibleFrame = anchorScreen.visibleFrame.insetBy(dx: -2, dy: -2)
        let horizontallyAligned = NSMidX(anchorFrame) >= popoverFrame.minX - 2
            && NSMidX(anchorFrame) <= popoverFrame.maxX + 2
        let verticalGap = anchorFrame.minY - popoverFrame.maxY
        let maximumArrowAndShadowGap = max(32, anchorFrame.height + 8)
        let verticallyAttached = verticalGap >= -4
            && verticalGap <= maximumArrowAndShadowGap
        e2eReporter.record("popover_geometry", fields: [
            "anchorAligned": horizontallyAligned && verticallyAttached,
            "fitsVisibleScreen": expandedVisibleFrame.contains(contentFrame),
            "horizontallyAligned": horizontallyAligned,
            "sameScreen": isSameDisplay(popoverScreen, anchorScreen),
            "verticallyAttached": verticallyAttached,
        ])
    }

    private func isSameDisplay(_ first: NSScreen, _ second: NSScreen) -> Bool {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard
            let firstNumber = first.deviceDescription[screenNumberKey] as? NSNumber,
            let secondNumber = second.deviceDescription[screenNumberKey] as? NSNumber
        else { return first.frame == second.frame }
        return firstNumber == secondNumber
    }

    private func reportActivePopoverIfNeeded() {
        guard
            e2eReporter.isEnabled,
            popover?.isShown == true,
            NSApp.isActive,
            !didReportActivePopover
        else { return }
        didReportActivePopover = true
        e2eReporter.record("popover_active")
    }

}

extension AppDelegate: StatusItemControllerDelegate {
    func statusItemDidRequestSpace(relativeTo positioningView: NSView) {
        checkReceiverHealth()
        if popover?.isShown != true {
            refreshHookStatusOnPopoverOpen()
        }
        toggleMeongSpace(relativeTo: positioningView)
    }

    func statusItemDidRequestHelp() {
        guard let url = URL(
            string: "https://github.com/dkstm95/agent-meong#readme"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func statusItemDidRequestQuit() {
        NSApp.terminate(nil)
    }
}

@MainActor
private final class MeongSpaceView: NSView {
    let connectionOverlay = ConnectionOverlayView(frame: .zero)
    let sceneView = SKView(frame: .zero)

    init(scene: MeongScene, size: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = scene.backgroundColor.cgColor
        addSceneView(scene)
        addConnectionOverlay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func addSceneView(_ scene: MeongScene) {
        let view = sceneView
        // Give SpriteKit the final canvas before presenting a `.resizeFill`
        // scene. The constraints take over immediately afterward, but a zero
        // initial frame would otherwise trigger a destructive zero-size resize.
        view.frame = bounds
        view.translatesAutoresizingMaskIntoConstraints = false
        view.preferredFramesPerSecond = 30
        view.ignoresSiblingOrder = true
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(
            L10n.text("에이전트 활동 장면", "Agent activity scene")
        )
        addSubview(view)

        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        view.presentScene(scene)
    }

    private func addConnectionOverlay() {
        connectionOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(connectionOverlay)
        NSLayoutConstraint.activate([
            connectionOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            connectionOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            connectionOverlay.topAnchor.constraint(equalTo: topAnchor),
            connectionOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
