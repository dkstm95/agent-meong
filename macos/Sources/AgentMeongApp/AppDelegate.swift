import AgentMeongCore
import AppKit
import SpriteKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var popover: NSPopover?
    private var scene: MeongScene?
    private var connectionOverlay: ConnectionOverlayView?
    private var statusController: StatusItemController?
    private var ticker: Timer?
    private var reducer = WorldReducer()
    private var socketServer: EventSocketServer?
    private var lastEventAt: Date?
    private var rejectedEventCount = 0
    private var receiverError: String?
    private var isDemo = false
    private let hookInstaller = CodexHookInstaller()
    private var hookInstallationState: CodexHookInstallationState = .checking
    private let e2eReporter = E2EReporter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        isDemo = ProcessInfo.processInfo.environment["AGENT_MEONG_DEMO"] == "1"
        hookInstallationState = hookInstaller.status()
        if isDemo {
            loadDemoWorld()
        }
        let world = reducer.state
        let scene = MeongScene(size: CGSize(width: 460, height: 500))
        scene.sync(with: world.intents)
        scene.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)

        let popover = makePopover(scene: scene)
        let statusController = StatusItemController(
            state: world.aggregateState,
            liveCount: world.liveActorCount,
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        render(world, at: .now)
        scheduleNextTick()
        e2eReporter.record("launched", fields: [
            "hookInstalled": hookInstallationState == .installed,
            "receiverReady": socketServer != nil,
            "popoverBehavior": popover.behavior == .transient ? "transient" : "other",
        ])

        if ProcessInfo.processInfo.environment["AGENT_MEONG_DEBUG_OPEN"] == "1" {
            DispatchQueue.main.async {
                statusController.showMeongSpaceForDebugging()
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        scene?.isPaused = true
        e2eReporter.record("popover_closed")
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

    @objc private func tick() {
        ticker = nil
        let now = Date.now
        let state = reducer.expire(at: now)
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
        lastEventAt = .now
        rejectedEventCount = 0
        let state = reducer.apply(observation)
        render(state, at: .now)
        scheduleNextTick()
        e2eReporter.record("observation", fields: [
            "aggregateState": state.aggregateState.rawValue,
            "liveActorCount": state.liveActorCount,
        ])
    }

    private func rejectEvent(_ reason: String) {
        rejectedEventCount += 1
        receiverError = nil
        render(reducer.state, at: .now)
    }

    private func render(_ state: WorldState, at now: Date) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        scene?.sync(with: state.intents)
        statusController?.update(
            state: state.aggregateState,
            liveCount: state.liveActorCount,
            sourceLabel: connectionLabel(at: now),
            reduceMotion: reduceMotion
        )
        connectionOverlay?.update(connectionDiagnostics, now: now)
    }

    private func makePopover(scene: MeongScene) -> NSPopover {
        let size = NSSize(width: 460, height: 500)
        let controller = NSViewController()
        let spaceView = MeongSpaceView(scene: scene, size: size)
        spaceView.connectionOverlay.onRetry = { [weak self] in self?.startEventServer() }
        spaceView.connectionOverlay.onInstall = { [weak self] in self?.installCodexHook() }
        connectionOverlay = spaceView.connectionOverlay
        controller.view = spaceView
        controller.view.appearance = NSAppearance(named: .darkAqua)
        controller.preferredContentSize = size

        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        return popover
    }

    private var connectionDiagnostics: ConnectionDiagnostics {
        ConnectionDiagnostics(
            receiverReady: socketServer != nil,
            lastEventAt: isDemo ? .now : lastEventAt,
            rejectedEventCount: rejectedEventCount,
            receiverError: receiverError,
            hookInstallationState: hookInstallationState
        )
    }

    private func installCodexHook() {
        hookInstallationState = hookInstaller.install()
        render(reducer.state, at: .now)
    }

    private func connectionLabel(at now: Date) -> String {
        if isDemo { return "Demo fixture" }
        if receiverError != nil { return "Codex · 수신기 오류" }
        if rejectedEventCount > 0 { return "Codex · 형식 확인" }
        guard let lastEventAt else { return "Codex · 실행 확인 필요" }
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

    @objc private func accessibilityDisplayOptionsChanged() {
        scene?.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        render(reducer.state, at: .now)
    }

    @objc private func applicationDidResignActive() {
        guard popover?.isShown == true else { return }
        popover?.close()
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
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self, weak popover] in
            guard let self, let popover else { return }
            e2eReporter.record("popover_opened", fields: ["appActive": NSApp.isActive])
            if ProcessInfo.processInfo.environment["AGENT_MEONG_E2E_CLOSE_POPOVER"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak popover] in
                    popover?.close()
                }
            }
        }
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
        let view = SKView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.preferredFramesPerSecond = 30
        view.ignoresSiblingOrder = true
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
