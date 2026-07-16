import AgentMeongCore
import AppKit
import SpriteKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
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
    private var didResolvePersistedConfirmation = false
    private var rejectedEventCount = 0
    private var receiverError: String?
    private var isDemo = false
    private var didReportActivePopover = false
    private let hookInstaller = CodexHookInstaller()
    private var hookInstallationState: CodexHookInstallationState = .checking
    private var inlineHooksPresent = false
    private var managedHookPresent = false
    private var currentHookInstanceID: String?
    private let e2eReporter = E2EReporter()
    private let lastConfirmedEventKey = "lastConfirmedCodexEventAt"
    private let lastConfirmedDefinitionKey = "lastConfirmedCodexHookDefinition"
    private let lastConfirmedInstanceKey = "lastConfirmedCodexHookInstance"
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
            "processID": Int(ProcessInfo.processInfo.processIdentifier),
            "receiverReady": socketServer != nil,
            "popoverBehavior": popover.behavior == .transient ? "transient" : "other",
        ])
        if ProcessInfo.processInfo.environment[
            "AGENT_MEONG_E2E_REPORT_LOCALIZATION"
        ] == "1" {
            e2eReporter.record("localization", fields: [
                "language": L10n.language.rawValue,
                "localizedSample": L10n.text("연결할 에이전트", "Connect an agent"),
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

    func popoverDidClose(_ notification: Notification) {
        scene?.isPaused = true
        popoverPositioningView = nil
        didReportActivePopover = false
        e2eReporter.record("popover_closed")
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
        guard popover?.isShown == true else { return }
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
        let state = reducer.expire(at: now)
        persistWorldState()
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
        let endedTopLevelWork = update.effects.contains { effect in
            effect == .topLevelFinished || effect == .topLevelCompleted
        }
        var workEndUnseen = false
        if endedTopLevelWork {
            workEndUnseen = statusController?.notifyWorkEnded(
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                markUnseen: popover?.isShown != true
            ) ?? false
        }
        scheduleNextTick()
        if update.observationAccepted {
            e2eReporter.record("observation", fields: [
                "activeActorCount": update.state.activeActorCount,
                "aggregateState": update.state.aggregateState.rawValue,
                "childAbsorptions": transitions.childAbsorptions,
                "childBirths": transitions.childBirths,
                "connectionGuidanceVisible": connectionOverlay?.isGuidanceVisible ?? false,
                "workEndNotified": endedTopLevelWork,
                "workEndUnseen": workEndUnseen,
                "liveActorCount": update.state.liveActorCount,
            ])
            autoRemoveCurrentHookForE2EIfNeeded()
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
            sourceLabel: connectionLabel(at: now),
            reduceMotion: reduceMotion,
            increaseContrast: increaseContrast
        )
        popover?.animates = !reduceMotion
        connectionOverlay?.setIncreaseContrast(increaseContrast)
        connectionOverlay?.update(connectionDiagnostics, now: now)
        sceneView?.setAccessibilityValue(sceneAccessibilitySummary(state))
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
            if shouldAutoConnectForE2E, hookInstallationState == .installed {
                connectionOverlay?.performPrimaryActionForE2E()
                e2eReporter.record("hook_installation", fields: [
                    "hookInstalled": true,
                    "hooksCommandCopied": connectionOverlay?.hooksCommandCopiedForE2E
                        ?? false,
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
        let connectionDelay = lastEventAt == nil ? nil : 10.0
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

    private func sceneAccessibilitySummary(_ state: WorldState) -> String {
        L10n.text(
            "\(L10n.stateLabel(state.aggregateState)). 실행 중 \(state.activeActorCount)개, 관찰 중 \(state.liveActorCount)개",
            "\(L10n.stateLabel(state.aggregateState)). \(state.activeActorCount) active, \(state.liveActorCount) observed"
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
        scene?.isPaused = false
        popoverPositioningView = positioningView
        popover.show(
            relativeTo: positioningView.bounds,
            of: positioningView,
            preferredEdge: .minY
        )
        popover.contentViewController?.view.window?.makeKey()
        statusController?.acknowledgeWorkEnd()
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
        view.translatesAutoresizingMaskIntoConstraints = false
        view.preferredFramesPerSecond = 30
        view.ignoresSiblingOrder = true
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(
            L10n.text("에이전트 활동 장면", "Agent activity scene")
        )
        view.presentScene(scene)
        addSubview(view)

        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
