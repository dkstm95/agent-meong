import AgentMeongCore
import AppKit
import SpriteKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let stateLegendVersion = 1

    private var popover: NSPopover?
    private weak var popoverPositioningView: NSView?
    private var scene: MeongScene?
    private var sceneView: SKView?
    private var connectionOverlay: ConnectionOverlayView?
    private var statusController: StatusItemController?
    private var ticker: Timer?
    private var reducer = WorldReducer()
    private var socketServer: EventSocketServer?
    private var lastEventAt: Date?
    private var previouslyConfirmedAt: Date?
    private var lastObservedIntegrationVersion: String?
    private var lastObservedIntegrationInstance: String?
    private var pendingConfirmationAt: Date?
    private var pendingConfirmationDefinitionID: String?
    private var pendingConfirmationInstanceID: String?
    private var shouldBindE2EConfirmationToCurrentDefinition = false
    private var didAutoConnectForE2E = false
    private var didAutoForgetForE2E = false
    private var didAutoRemoveHookForE2E = false
    private var didAutoReopenStateLegendForE2E = false
    private var didScheduleCompletionReceiptOpenForE2E = false
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
    private var hookInstallationState: CodexHookInstallationState = .checking
    private var inlineHooksPresent = false
    private var managedHookPresent = false
    private var currentHookInstanceID: String?
    private let e2eReporter = E2EReporter()
    private let lastConfirmedEventKey = "lastConfirmedCodexEventAt"
    private let lastConfirmedDefinitionKey = "lastConfirmedCodexHookDefinition"
    private let lastConfirmedInstanceKey = "lastConfirmedCodexHookInstance"
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
            pendingConfirmationAt = connectionDefaults.object(forKey: lastConfirmedEventKey) as? Date
            pendingConfirmationDefinitionID = connectionDefaults.string(
                forKey: lastConfirmedDefinitionKey
            )
            pendingConfirmationInstanceID = connectionDefaults.string(
                forKey: lastConfirmedInstanceKey
            )
        }
        if isDemo {
            loadDemoWorld()
        }
        let world = reducer.state
        let scene = MeongScene(size: CGSize(width: 460, height: 500))
        scene.sync(with: world.intents)
        scene.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
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
            "processID": Int(ProcessInfo.processInfo.processIdentifier),
            "receiverReady": socketServer != nil,
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
                "localizedSample": L10n.text("연결할 에이전트", "Connect an agent"),
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
        if !isDemo {
            refreshHookStatus(openOnboarding: !debugOpen && !suppressOpen)
        }
        if debugOpen {
            DispatchQueue.main.async {
                statusController.presentMeongSpace()
            }
        }
    }

    func popoverWillClose(_ notification: Notification) {
        cancelStateLegendForRetry()
        scene?.discardTransientPresentation()
    }

    func popoverDidClose(_ notification: Notification) {
        if isHoldingStateLegendRetryPopoverForE2E {
            isHoldingStateLegendRetryPopoverForE2E = false
            popover?.behavior = .transient
        }
        cancelStateLegendForRetry()
        scene?.discardTransientPresentation()
        scene?.isPaused = true
        popoverPositioningView = nil
        didReportActivePopover = false
        e2eReporter.record("popover_closed")
        autoReopenStateLegendForE2EIfNeeded()
    }

    func popoverDidShow(_ notification: Notification) {
        reportActivePopoverIfNeeded()
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
        let receivedAt = Date.now
        lastEventAt = receivedAt
        previouslyConfirmedAt = receivedAt
        lastObservedIntegrationVersion = observation.integrationVersion
        lastObservedIntegrationInstance = observation.integrationInstance
        if shouldPersistConnectionHistory {
            connectionDefaults.set(receivedAt, forKey: lastConfirmedEventKey)
            if let integrationVersion = observation.integrationVersion {
                connectionDefaults.set(
                    integrationVersion,
                    forKey: lastConfirmedDefinitionKey
                )
            } else {
                connectionDefaults.removeObject(forKey: lastConfirmedDefinitionKey)
            }
            if let integrationInstance = observation.integrationInstance {
                connectionDefaults.set(
                    integrationInstance,
                    forKey: lastConfirmedInstanceKey
                )
            } else {
                connectionDefaults.removeObject(forKey: lastConfirmedInstanceKey)
            }
            synchronizeConnectionDefaultsForE2E()
        }
        rejectedEventCount = 0
        let update = reducer.applyWithEffects(observation)
        if update.observationAccepted {
            persistWorldState()
        }
        let effects = popover?.isShown == true ? update.effects : []
        let transitions = render(update.state, at: receivedAt, effects: effects)
        let completionReceipts = update.effects.compactMap(completionReceipt)
        let endedTopLevelWork = !completionReceipts.isEmpty
        var workEndUnseen = false
        if endedTopLevelWork {
            if popover?.isShown != true {
                completionReceipts.forEach { receipt in
                    scene?.registerCompletionReceipt(for: receipt.actorId, kind: receipt.kind)
                }
            }
            let unseenCount = scene?.pendingCompletionReceiptCount ?? 0
            workEndUnseen = (statusController?.notifyWorkEnded(
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                unseenCount: unseenCount
            ) ?? 0) > 0
        }
        scheduleNextTick()
        if update.observationAccepted {
            queueStateLegendAfterAcceptedObservation()
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
                "workEndNotified": endedTopLevelWork,
                "workEndUnseen": workEndUnseen,
                "liveActorCount": update.state.liveActorCount,
                "toolFinishes": transitions.toolFinishes,
                "toolStarts": transitions.toolStarts,
                "unseenWorkEndCount": scene?.pendingCompletionReceiptCount ?? 0,
            ])
            autoRemoveCurrentHookForE2EIfNeeded()
            autoOpenCompletionReceiptsForE2EIfNeeded()
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
    }

    @discardableResult
    private func render(
        _ state: WorldState,
        at now: Date,
        effects: [WorldEffect] = []
    ) -> SceneTransitionSummary {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
            completionReceiptCount: scene?.pendingCompletionReceiptCount ?? 0
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
        spaceView.connectionOverlay.onRefreshHookStatus = { [weak self] in
            self?.refreshHookStatus(openOnboarding: false)
        }
        spaceView.connectionOverlay.onUninstall = { [weak self] in self?.uninstallCodexHook() }
        spaceView.connectionOverlay.onForget = { [weak self] in self?.forgetConnectionHistory() }
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
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        return popover
    }

    private var connectionDiagnostics: ConnectionDiagnostics {
        ConnectionDiagnostics(
            receiverReady: socketServer != nil,
            lastEventAt: isDemo ? .now : lastEventAt,
            previouslyConfirmedAt: isDemo ? .now : previouslyConfirmedAt,
            rejectedEventCount: rejectedEventCount,
            receiverError: receiverError,
            hookInstallationState: hookInstallationState,
            inlineHooksPresent: inlineHooksPresent,
            managedHookPresent: managedHookPresent,
            hookProblemOverridesHistory: hookProblemOverridesHistory,
            observedConnectionIsCurrentHook: observedConnectionIsCurrentHook
        )
    }

    private func installCodexHook() {
        let installationStartedAt = Date.now
        hookInstallationState = .checking
        render(reducer.state, at: .now)
        Task { [weak self] in
            guard let self else { return }
            let result = await hookInstaller.install()
            if result.state == .installed {
                let observedCurrentDefinitionDuringInstall = lastEventAt.map {
                    $0 >= installationStartedAt
                } == true
                    && lastObservedIntegrationVersion == result.definitionID
                    && lastObservedIntegrationInstance == result.instanceID
                let observedSeparateCustomConnection = lastObservedIntegrationInstance != nil
                    && lastObservedIntegrationInstance != result.instanceID
                if !observedCurrentDefinitionDuringInstall, !observedSeparateCustomConnection {
                    clearConnectionConfirmation()
                }
            }
            applyHookInstallationResult(result)
            render(reducer.state, at: .now)
            let hooksCommandCopied = hookInstallationState == .installed
                && (connectionOverlay?.copyHooksCommandAfterInstallation() ?? false)
            if shouldAutoConnectForE2E, hookInstallationState == .installed {
                e2eReporter.record("hook_installation", fields: [
                    "hookInstalled": true,
                    "hooksCommandCopied": hooksCommandCopied
                        && (connectionOverlay?.hooksCommandCopiedForE2E ?? false),
                ])
            }
        }
    }

    private func uninstallCodexHook() {
        let removedInstanceID = currentHookInstanceID
        let shouldClearObservedConnection = HookRemovalPolicy.shouldClearObservedConnection(
            hasObservedConnection: lastEventAt != nil || previouslyConfirmedAt != nil,
            observedInstanceID: lastObservedIntegrationInstance,
            removedInstanceID: removedInstanceID
        )
        hookInstallationState = .checking
        render(reducer.state, at: .now)
        Task { [weak self] in
            guard let self else { return }
            applyHookInstallationResult(await hookInstaller.uninstall())
            if hookInstallationState == .notInstalled, shouldClearObservedConnection {
                clearConnectionConfirmation()
            }
            render(reducer.state, at: .now)
            e2eReporter.record("hook_removal", fields: [
                "confirmationCleared": isConnectionConfirmationCleared,
                "hookInstalled": hookInstallationState == .installed,
                "hookState": hookStateLabel,
                "liveActorCount": reducer.state.liveActorCount,
                "managedHookPresent": managedHookPresent,
            ])
        }
    }

    private func refreshHookStatus(openOnboarding: Bool) {
        hookInstallationState = .checking
        render(reducer.state, at: .now)
        Task { [weak self] in
            guard let self else { return }
            let result = await hookInstaller.status()
            applyHookInstallationResult(result)
            reconcilePersistedConfirmation(with: result)
            render(reducer.state, at: .now)
            let needsOnboarding = lastEventAt == nil
                && (previouslyConfirmedAt == nil || hookProblemOverridesHistory)
            e2eReporter.record("hook_status", fields: [
                "connectionGuidanceVisible": connectionOverlay?.isGuidanceVisible ?? false,
                "hookInstalled": hookInstallationState == .installed,
                "hookState": hookStateLabel,
                "inlineHooksPresent": inlineHooksPresent,
                "managedHookPresent": managedHookPresent,
                "onboardingNeeded": needsOnboarding,
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
            if openOnboarding, needsOnboarding {
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
        }
    }

    private func applyHookInstallationResult(_ result: CodexHookInstallationResult) {
        hookInstallationState = result.state
        inlineHooksPresent = result.inlineHooksPresent
        managedHookPresent = result.managedHookPresent
        currentHookInstanceID = result.instanceID
    }

    private func clearConnectionConfirmation() {
        lastEventAt = nil
        previouslyConfirmedAt = nil
        lastObservedIntegrationVersion = nil
        lastObservedIntegrationInstance = nil
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
            synchronizeConnectionDefaultsForE2E()
        }
        scheduleNextTick()
    }

    private func forgetConnectionHistory() {
        clearConnectionConfirmation()
        render(reducer.state, at: .now)
        connectionOverlay?.showGuidance()
        e2eReporter.record("connection_forget", fields: [
            "confirmationCleared": isConnectionConfirmationCleared,
            "connectionGuidanceVisible": connectionOverlay?.isGuidanceVisible ?? false,
        ])
    }

    private func reconcilePersistedConfirmation(
        with result: CodexHookInstallationResult
    ) {
        guard !didResolvePersistedConfirmation, let definitionID = result.definitionID else {
            return
        }
        didResolvePersistedConfirmation = true
        if lastEventAt != nil {
            pendingConfirmationAt = nil
            pendingConfirmationDefinitionID = nil
            pendingConfirmationInstanceID = nil
            return
        }
        let storedDefinitionID = shouldBindE2EConfirmationToCurrentDefinition
            ? definitionID
            : pendingConfirmationDefinitionID
        let storedInstanceID = shouldBindE2EConfirmationToCurrentDefinition
            ? result.instanceID
            : pendingConfirmationInstanceID
        if
            let date = pendingConfirmationAt,
            storedDefinitionID == definitionID,
            let storedInstanceID
        {
            previouslyConfirmedAt = date
            lastObservedIntegrationVersion = storedDefinitionID
            lastObservedIntegrationInstance = storedInstanceID
            if shouldPersistWorldState {
                restorePersistedWorld(at: .now)
            }
        } else {
            previouslyConfirmedAt = nil
            try? worldCheckpointStore.clear()
            if shouldPersistConnectionHistory {
                connectionDefaults.removeObject(forKey: lastConfirmedEventKey)
                connectionDefaults.removeObject(forKey: lastConfirmedDefinitionKey)
                connectionDefaults.removeObject(forKey: lastConfirmedInstanceKey)
                synchronizeConnectionDefaultsForE2E()
            }
        }
        pendingConfirmationAt = nil
        pendingConfirmationDefinitionID = nil
        pendingConfirmationInstanceID = nil
        scheduleNextTick()
    }

    private var hookProblemOverridesHistory: Bool {
        guard
            lastEventAt == nil,
            previouslyConfirmedAt != nil
        else { return false }
        switch hookInstallationState {
        case .checking, .installed:
            return false
        case .notInstalled, .needsRepair, .invalidConfiguration, .hooksDisabled,
            .managedHooksOnly, .newerVersion, .unavailable:
            if
                let observedInstance = lastObservedIntegrationInstance,
                let currentInstance = currentHookInstanceID
            {
                return observedInstance == currentInstance
            }
            // A pre-companion installation can have a real managed hook but no
            // instance id. Surface its repair state without deleting a possibly
            // separate custom-home confirmation.
            return managedHookPresent && currentHookInstanceID == nil
        }
    }

    private var observedConnectionIsCurrentHook: Bool {
        lastObservedIntegrationInstance != nil
            && lastObservedIntegrationInstance == currentHookInstanceID
    }

    private func connectionLabel(at now: Date) -> String {
        if isDemo { return L10n.text("데모 fixture", "Demo fixture") }
        if receiverError != nil {
            return L10n.text("Codex · 수신기 오류", "Codex · receiver error")
        }
        if rejectedEventCount > 0 {
            return L10n.text("Codex · 형식 확인", "Codex · check format")
        }
        if let lastEventAt {
            return "Codex · \(L10n.relativeAge(from: lastEventAt, to: now))"
        }
        if previouslyConfirmedAt != nil, !hookProblemOverridesHistory {
            return L10n.text("Codex · 이벤트 대기", "Codex · waiting for event")
        }
        switch hookInstallationState {
        case .notInstalled:
            return L10n.text("Codex · 연결 필요", "Codex · connect")
        case .hooksDisabled:
            return L10n.text("Codex · hooks 꺼짐", "Codex · hooks off")
        case .managedHooksOnly:
            return L10n.text("Codex · 정책 제한", "Codex · policy blocked")
        case .newerVersion:
            return L10n.text("Codex · 앱 업데이트", "Codex · update app")
        case .invalidConfiguration:
            return L10n.text("Codex · 설정 확인", "Codex · check config")
        case .needsRepair:
            return L10n.text("Codex · 복구 필요", "Codex · repair")
        case .unavailable:
            return L10n.text("Codex · 상태 오류", "Codex · status error")
        case .checking, .installed: break
        }
        return L10n.text("Codex · 확인 필요", "Codex · check connection")
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
    }

    private func reconcileStateLegendPresentation() {
        guard
            stateLegendInFlight,
            connectionOverlay?.isStateLegendVisible != true,
            !hasSeenStateLegend
        else { return }
        stateLegendInFlight = false
        stateLegendPending = true
    }

    private func stateLegendWasCancelled() {
        stateLegendInFlight = false
        stateLegendPending = !hasSeenStateLegend
    }

    private func cancelStateLegendForRetry() {
        guard stateLegendInFlight, !hasSeenStateLegend else { return }
        connectionOverlay?.cancelStateLegend()
        // Keep the state correct even if the overlay has already hidden itself
        // and therefore has no cancellation callback left to send.
        stateLegendInFlight = false
        stateLegendPending = true
    }

    private func presentPendingStateLegendIfPossible() {
        guard
            stateLegendPending,
            !stateLegendInFlight,
            !hasSeenStateLegend,
            popover?.isShown == true,
            let connectionOverlay,
            !connectionOverlay.isGuidanceVisible
        else { return }

        let duration = stateLegendPresentationDuration
        let shown = connectionOverlay.presentStateLegend(
            duration: duration,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ) { [weak self] in
            guard let self else { return }
            stateLegendInFlight = false
            stateLegendPending = false
            stateLegendSeenThisRun = true
            if shouldPersistConnectionHistory {
                connectionDefaults.set(Self.stateLegendVersion, forKey: stateLegendVersionKey)
                synchronizeConnectionDefaultsForE2E()
            }
            let closesRetryPopover = isHoldingStateLegendRetryPopoverForE2E
            let popoverBehaviorRestored = restoreStateLegendRetryPopoverForE2EIfNeeded()
            e2eReporter.record("state_legend_completed", fields: [
                "popoverBehaviorRestored": popoverBehaviorRestored,
                "stateLegendAccessible": connectionOverlay.isStateLegendAccessible,
                "stateLegendVersion": Self.stateLegendVersion,
                "stateLegendVisible": connectionOverlay.isStateLegendVisible,
            ])
            if closesRetryPopover {
                DispatchQueue.main.async { [weak self] in
                    self?.popover?.performClose(nil)
                }
            }
        }
        guard shown else { return }
        stateLegendPending = false
        stateLegendInFlight = true
        e2eReporter.record("state_legend_shown", fields: [
            "stateLegendAccessible": connectionOverlay.isStateLegendAccessible,
            "stateLegendVersion": Self.stateLegendVersion,
            "stateLegendVisible": connectionOverlay.isStateLegendVisible,
        ])
    }

    private var stateLegendPresentationDuration: TimeInterval {
        guard e2eReporter.isEnabled else { return 4 }
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
        // Let the Finder activation that closed the transient popover settle
        // before the test reopens it. Reopening inside the same activation
        // transition can receive a delayed resign-active callback and close
        // the second legend before its timer completes.
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
            let observedInstanceID = lastObservedIntegrationInstance,
            let currentInstanceID = currentHookInstanceID,
            observedInstanceID != currentInstanceID
        else { return }
        didAutoRemoveHookForE2E = true
        connectionOverlay?.performHookRemovalForE2E()
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
        guard shouldPersistConnectionHistory else { return memoryCleared }
        return memoryCleared
            && connectionDefaults.object(forKey: lastConfirmedEventKey) == nil
            && connectionDefaults.object(forKey: lastConfirmedDefinitionKey) == nil
            && connectionDefaults.object(forKey: lastConfirmedInstanceKey) == nil
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
        let details = L10n.text(
            "조용함 \(state.quietActorCount)개, 활동 중 \(state.activeActorCount)개, 확인 필요 \(state.attentionActorCount)개, 불확실 \(state.uncertainActorCount)개, 종료 \(state.finishedActorCount)개, 완료 \(state.completedActorCount)개, 취소 \(state.cancelledActorCount)개, 실패 \(state.failedActorCount)개",
            "\(state.quietActorCount) quiet, \(state.activeActorCount) active, \(state.attentionActorCount) need attention, \(state.uncertainActorCount) uncertain, \(state.finishedActorCount) finished, \(state.completedActorCount) completed, \(state.cancelledActorCount) cancelled, \(state.failedActorCount) failed"
        )
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
            "움직임은 활동 중, 고리는 확인 필요, 분절 고리는 불확실, 열린 호는 종료, 이중 후광은 완료, 가로 막대는 취소, 마름모는 실패, 바깥으로 번지는 파동은 방금 관찰된 턴 종료를 뜻합니다. 부모와 자식은 같은 색 계열을 공유하지만 색은 고유 ID가 아닙니다.",
            "Movement means active, a ring means needs attention, a segmented ring means uncertain, an open arc means finished, a double halo means completed, a horizontal bar means cancelled, a diamond means failed, and an outward ripple means a newly observed turn end. Related parents and children share a color family, but color is not a unique ID."
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
            self?.showMeongSpace(relativeTo: positioningView)
        }
    }

    private func showMeongSpace(relativeTo positioningView: NSView) {
        guard let popover, !popover.isShown else { return }
        render(reducer.state, at: .now)
        scene?.isPaused = false
        popoverPositioningView = positioningView
        popover.show(
            relativeTo: positioningView.bounds,
            of: positioningView,
            preferredEdge: .minY
        )
        popover.contentViewController?.view.window?.makeKey()
        let completionReceiptCount = scene?.presentCompletionReceipts() ?? 0
        if completionReceiptCount > 0 {
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
            let acknowledgedAccessibilitySummary = sceneAccessibilitySummary(
                reducer.state,
                completionReceiptCount: 0
            )
            sceneView?.setAccessibilityValue(acknowledgedAccessibilitySummary)
            let receiptsAcknowledged = scene?.pendingCompletionReceiptCount == 0
                && sceneView?.accessibilityValue() as? String
                    == acknowledgedAccessibilitySummary
            e2eReporter.record("completion_receipts_presented", fields: [
                "completionReceiptCount": completionReceiptCount,
                "completionReceiptsAccessible": receiptsAccessible,
                "completionReceiptsAcknowledged": receiptsAcknowledged,
            ])
        }
        statusController?.acknowledgeWorkEnd()
        presentPendingStateLegendIfPossible()
        didReportActivePopover = false
        e2eReporter.record("popover_opened")
        NSApp.activate(ignoringOtherApps: true)
        reportActivePopoverIfNeeded()
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
        toggleMeongSpace(relativeTo: positioningView)
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
