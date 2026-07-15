import AgentMeongCore
import AppKit
import SpriteKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var popover: NSPopover?
    private var scene: MeongScene?
    private var sceneView: SKView?
    private var connectionOverlay: ConnectionOverlayView?
    private var statusController: StatusItemController?
    private var ticker: Timer?
    private var reducer = WorldReducer()
    private var socketServer: EventSocketServer?
    private var lastEventAt: Date?
    private var previouslyConfirmedAt: Date?
    private var rejectedEventCount = 0
    private var receiverError: String?
    private var isDemo = false
    private var didReportActivePopover = false
    private let hookInstaller = CodexHookInstaller()
    private var hookInstallationState: CodexHookInstallationState = .checking
    private let e2eReporter = E2EReporter()
    private let lastConfirmedEventKey = "lastConfirmedCodexEventAt"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateExistingInstanceIfNeeded() { return }
        isDemo = ProcessInfo.processInfo.environment["AGENT_MEONG_DEMO"] == "1"
        if ProcessInfo.processInfo.environment["AGENT_MEONG_E2E_PREVIOUSLY_CONFIRMED"] == "1" {
            previouslyConfirmedAt = .now.addingTimeInterval(-60)
        } else if shouldPersistConnectionHistory {
            previouslyConfirmedAt = UserDefaults.standard.object(forKey: lastConfirmedEventKey) as? Date
        }
        if isDemo {
            loadDemoWorld()
        } else if shouldPersistWorldState {
            if previouslyConfirmedAt != nil {
                restorePersistedWorld(at: .now)
            } else {
                try? worldCheckpointStore.clear()
            }
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
            "receiverReady": socketServer != nil,
            "popoverBehavior": popover.behavior == .transient ? "transient" : "other",
        ])

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
        didReportActivePopover = false
        e2eReporter.record("popover_closed")
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
        if shouldPersistConnectionHistory {
            UserDefaults.standard.set(receivedAt, forKey: lastConfirmedEventKey)
        }
        rejectedEventCount = 0
        let update = reducer.applyWithEffects(observation)
        if update.observationAccepted {
            persistWorldState()
        }
        let effects = popover?.isShown == true ? update.effects : []
        let transitions = render(update.state, at: receivedAt, effects: effects)
        let completedTopLevelWork = update.effects.contains(.topLevelCompleted)
        var completionUnseen = false
        if completedTopLevelWork {
            completionUnseen = statusController?.notifyCompletion(
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
                "completionNotified": completedTopLevelWork,
                "completionUnseen": completionUnseen,
                "liveActorCount": update.state.liveActorCount,
            ])
        }
    }

    private func rejectEvent(_ reason: String) {
        rejectedEventCount += 1
        receiverError = nil
        render(reducer.state, at: .now)
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
        spaceView.connectionOverlay.onUninstall = { [weak self] in self?.uninstallCodexHook() }
        spaceView.connectionOverlay.onOpenCodex = { [weak self] in self?.openCodexApp() }
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
            codexAppAvailable: codexAppAvailable
        )
    }

    private func installCodexHook() {
        hookInstallationState = .checking
        render(reducer.state, at: .now)
        Task { [weak self] in
            guard let self else { return }
            hookInstallationState = await hookInstaller.install()
            render(reducer.state, at: .now)
        }
    }

    private func uninstallCodexHook() {
        hookInstallationState = .checking
        render(reducer.state, at: .now)
        Task { [weak self] in
            guard let self else { return }
            hookInstallationState = await hookInstaller.uninstall()
            if hookInstallationState == .notInstalled {
                lastEventAt = nil
                previouslyConfirmedAt = nil
                rejectedEventCount = 0
                reducer = WorldReducer()
                try? worldCheckpointStore.clear()
                if shouldPersistConnectionHistory {
                    UserDefaults.standard.removeObject(forKey: lastConfirmedEventKey)
                }
                scheduleNextTick()
            }
            render(reducer.state, at: .now)
        }
    }

    private func refreshHookStatus(openOnboarding: Bool) {
        Task { [weak self] in
            guard let self else { return }
            hookInstallationState = await hookInstaller.status()
            render(reducer.state, at: .now)
            let needsOnboarding = hookInstallationState != .installed
                || previouslyConfirmedAt == nil
            e2eReporter.record("hook_status", fields: [
                "connectionGuidanceVisible": connectionOverlay?.isGuidanceVisible ?? false,
                "hookInstalled": hookInstallationState == .installed,
                "onboardingNeeded": needsOnboarding,
            ])
            if openOnboarding, needsOnboarding {
                statusController?.presentMeongSpace()
            }
        }
    }

    private func openCodexApp() {
        guard let url = codexNewTaskURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func connectionLabel(at now: Date) -> String {
        if isDemo { return "Demo fixture" }
        if receiverError != nil { return "Codex · 수신기 오류" }
        if rejectedEventCount > 0 { return "Codex · 형식 확인" }
        if hookInstallationState == .notInstalled { return "Codex · 연결 필요" }
        guard let lastEventAt else {
            return previouslyConfirmedAt == nil ? "Codex · 확인 필요" : "Codex · 이벤트 대기"
        }
        let seconds = max(0, Int(now.timeIntervalSince(lastEventAt)))
        if seconds < 10 { return "Codex · 방금" }
        if seconds < 60 { return "Codex · \(seconds)초 전" }
        return "Codex · \(seconds / 60)분 전"
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

    private var codexNewTaskURL: URL? {
        URL(string: "codex://threads/new")
    }

    private var shouldPersistConnectionHistory: Bool {
        !isDemo && ProcessInfo.processInfo.environment["AGENT_MEONG_E2E_REPORT"] == nil
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

    private var codexAppAvailable: Bool {
        guard let codexNewTaskURL else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: codexNewTaskURL) != nil
    }

    private func sceneAccessibilitySummary(_ state: WorldState) -> String {
        let stateLabel: String = switch state.aggregateState {
        case .quiet: "고요함"
        case .active: "활동 중"
        case .attention: "확인 필요"
        case .uncertain: "상태 불확실"
        case .completed: "완료"
        case .cancelled: "취소됨"
        case .failed: "실패 확인 필요"
        }
        return "\(stateLabel). 실행 중 \(state.activeActorCount)개, 관찰 중 \(state.liveActorCount)개"
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
        popover.show(
            relativeTo: positioningView.bounds,
            of: positioningView,
            preferredEdge: .minY
        )
        popover.contentViewController?.view.window?.makeKey()
        statusController?.acknowledgeCompletion()
        didReportActivePopover = false
        e2eReporter.record("popover_opened")
        DispatchQueue.main.async { [weak self, weak positioningView] in
            guard let positioningView else { return }
            self?.reportPopoverGeometry(relativeTo: positioningView)
        }
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
        let verticallyAttached = abs(popoverFrame.maxY - anchorFrame.minY) <= 16
        e2eReporter.record("popover_geometry", fields: [
            "anchorAligned": horizontallyAligned && verticallyAttached,
            "fitsVisibleScreen": expandedVisibleFrame.contains(contentFrame),
            "sameScreen": isSameDisplay(popoverScreen, anchorScreen),
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
        view.setAccessibilityLabel("에이전트 활동 장면")
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
