import AppKit

private final class StateLegendSignalView: NSView {
    enum Kind {
        case movement
        case attention
        case turnEnded
    }

    private let kind: Kind
    private let primaryLayer = CAShapeLayer()
    private let secondaryLayer = CAShapeLayer()
    private var reduceMotion = false
    private var increaseContrast = false

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(secondaryLayer)
        layer?.addSublayer(primaryLayer)
        [primaryLayer, secondaryLayer].forEach {
            $0.fillColor = NSColor.clear.cgColor
            $0.lineCap = .round
            $0.lineJoin = .round
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        primaryLayer.frame = bounds
        secondaryLayer.frame = bounds
        updatePaths()
    }

    func updatePresentation(reduceMotion: Bool, increaseContrast: Bool) {
        self.reduceMotion = reduceMotion
        self.increaseContrast = increaseContrast
        updatePaths()
        updateAnimations()
    }

    func stopAnimations() {
        primaryLayer.removeAllAnimations()
        secondaryLayer.removeAllAnimations()
    }

    var hasNoAnimationsForE2E: Bool {
        (layer?.animationKeys()?.isEmpty ?? true)
            && (primaryLayer.animationKeys()?.isEmpty ?? true)
            && (secondaryLayer.animationKeys()?.isEmpty ?? true)
    }

    var isStaticChevronForE2E: Bool {
        kind == .movement
            && reduceMotion
            && primaryLayer.path != nil
            && secondaryLayer.path == nil
            && hasNoAnimationsForE2E
    }

    private func updatePaths() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let foreground = NSColor.white.withAlphaComponent(increaseContrast ? 1 : 0.88)
        let secondary = NSColor.white.withAlphaComponent(increaseContrast ? 0.82 : 0.38)
        primaryLayer.strokeColor = foreground.cgColor
        primaryLayer.fillColor = NSColor.clear.cgColor
        primaryLayer.lineWidth = increaseContrast ? 2 : 1.5
        secondaryLayer.strokeColor = secondary.cgColor
        secondaryLayer.fillColor = NSColor.clear.cgColor
        secondaryLayer.lineWidth = increaseContrast ? 1.5 : 1

        switch kind {
        case .movement:
            if reduceMotion {
                let chevron = CGMutablePath()
                chevron.move(to: CGPoint(x: center.x - 4, y: center.y - 6))
                chevron.addLine(to: CGPoint(x: center.x + 3, y: center.y))
                chevron.addLine(to: CGPoint(x: center.x - 4, y: center.y + 6))
                primaryLayer.path = chevron
                secondaryLayer.path = nil
            } else {
                primaryLayer.path = CGPath(
                    ellipseIn: CGRect(
                        x: center.x - 3.25,
                        y: center.y - 3.25,
                        width: 6.5,
                        height: 6.5
                    ),
                    transform: nil
                )
                primaryLayer.fillColor = foreground.cgColor
                let track = CGMutablePath()
                track.move(to: CGPoint(x: center.x, y: center.y - 7))
                track.addLine(to: CGPoint(x: center.x, y: center.y + 7))
                secondaryLayer.path = track
            }
        case .attention:
            primaryLayer.path = CGPath(
                ellipseIn: CGRect(x: center.x - 6.5, y: center.y - 6.5, width: 13, height: 13),
                transform: nil
            )
            secondaryLayer.path = CGPath(
                ellipseIn: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3),
                transform: nil
            )
            secondaryLayer.fillColor = foreground.cgColor
        case .turnEnded:
            primaryLayer.path = CGPath(
                ellipseIn: CGRect(x: center.x - 2.25, y: center.y - 2.25, width: 4.5, height: 4.5),
                transform: nil
            )
            primaryLayer.fillColor = foreground.cgColor
            secondaryLayer.path = CGPath(
                ellipseIn: CGRect(x: center.x - 6.5, y: center.y - 6.5, width: 13, height: 13),
                transform: nil
            )
        }
    }

    private func updateAnimations() {
        stopAnimations()
        guard !reduceMotion else { return }
        switch kind {
        case .movement:
            let bounce = CABasicAnimation(keyPath: "transform.translation.y")
            bounce.fromValue = -3
            bounce.toValue = 3
            bounce.duration = 0.48
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            primaryLayer.add(bounce, forKey: "state-legend-bounce")
        case .attention:
            break
        case .turnEnded:
            let ripple = CAAnimationGroup()
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.55
            scale.toValue = 1.25
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.95
            fade.toValue = 0.12
            ripple.animations = [scale, fade]
            ripple.duration = 1.05
            ripple.repeatCount = .infinity
            ripple.timingFunction = CAMediaTimingFunction(name: .easeOut)
            secondaryLayer.add(ripple, forKey: "state-legend-ripple")
        }
    }
}

private enum ConnectionPrimaryAction: Equatable {
    case hidden
    case retryReceiver
    case connect
    case repair
    case refreshStatus
    case review
}

private enum ConnectionGuidanceProblem: Equatable {
    case receiver
    case rejectedEvent
    case hook(CodexHookInstallationState)
    case runtime(CodexHookRuntimeStatus, [String])
}

struct ConnectionDiagnostics {
    let receiverReady: Bool
    let lastEventAt: Date?
    let previouslyConfirmedAt: Date?
    let rejectedEventCount: Int
    let receiverError: String?
    let hookInstallationState: CodexHookInstallationState
    let inlineHooksPresent: Bool
    let managedHookPresent: Bool
    let hookRuntimeStatus: CodexHookRuntimeStatus
    let runtimeProblemEvents: [String]
    let reviewLaunchState: CodexReviewLaunchState
    let hookProblemOverridesHistory: Bool
    let currentHookConfirmedAt: Date?
    let hasSeparateConnectionConfirmation: Bool

    var hasObservedHistory: Bool {
        lastEventAt != nil || previouslyConfirmedAt != nil
    }

    var hasConfirmedConnection: Bool {
        hasObservedHistory && !hookProblemOverridesHistory
    }

    var runtimeIsReady: Bool {
        managedHookPresent
            && hookInstallationState == .installed
            && hookRuntimeStatus == .ready
    }

    var hookProblemShouldLead: Bool {
        let requiresGuidance: Bool
        switch hookInstallationState {
        case .checking, .installed:
            requiresGuidance = false
        case .notInstalled, .needsRepair, .invalidConfiguration,
            .hooksDisabled, .managedHooksOnly, .newerVersion, .unavailable:
            requiresGuidance = true
        }
        return requiresGuidance
            && (!hasObservedHistory || hookProblemOverridesHistory || managedHookPresent)
    }

    var runtimeProblemShouldLead: Bool {
        guard managedHookPresent else { return false }
        return hookRuntimeStatus == .reviewRequired || hookRuntimeStatus == .disabled
    }

    var needsOnboarding: Bool {
        receiverError != nil
            || rejectedEventCount > 0
            || hookProblemShouldLead
            || runtimeProblemShouldLead
            || (!hasConfirmedConnection && !runtimeIsReady)
    }

    var hasOnlySeparateConnection: Bool {
        hookInstallationState == .notInstalled && hasSeparateConnectionConfirmation
    }

    fileprivate var primaryAction: ConnectionPrimaryAction {
        if receiverError != nil {
            return .retryReceiver
        }
        if rejectedEventCount > 0 {
            return hookInstallationState == .needsRepair ? .repair : .refreshStatus
        }
        // A separate CODEX_HOME can keep the aggregate connection confirmed,
        // but it must not make the default ~/.codex impossible to connect.
        if hookInstallationState == .notInstalled {
            return .connect
        }
        if hookProblemShouldLead {
            switch hookInstallationState {
            case .needsRepair:
                return .repair
            case .invalidConfiguration, .hooksDisabled, .managedHooksOnly, .unavailable:
                return .refreshStatus
            case .checking, .notInstalled, .installed, .newerVersion:
                return .hidden
            }
        }
        if runtimeProblemShouldLead {
            return reviewLaunchState == .opening ? .hidden : .review
        }
        if hasConfirmedConnection {
            return .hidden
        }
        switch hookInstallationState {
        case .checking, .newerVersion:
            return .hidden
        case .notInstalled:
            return .connect
        case .needsRepair:
            return .repair
        case .invalidConfiguration, .hooksDisabled, .managedHooksOnly, .unavailable:
            return .refreshStatus
        case .installed:
            switch hookRuntimeStatus {
            case .checking, .ready:
                return .hidden
            case .reviewRequired, .disabled:
                return reviewLaunchState == .opening ? .hidden : .review
            case .unavailable:
                return .refreshStatus
            }
        }
    }

    fileprivate var guidanceProblem: ConnectionGuidanceProblem? {
        if receiverError != nil {
            return .receiver
        }
        if rejectedEventCount > 0 {
            return .rejectedEvent
        }
        if hookProblemShouldLead {
            return .hook(hookInstallationState)
        }
        if runtimeProblemShouldLead {
            return .runtime(hookRuntimeStatus, runtimeProblemEvents)
        }
        return nil
    }
}

@MainActor
final class ConnectionOverlayView: NSView {
    var onRetry: (() -> Void)?
    var onInstall: (() -> Void)?
    var onReview: (() -> Void)?
    var onRefreshHookStatus: (() -> Void)?
    var onUninstall: (() -> Void)?
    var onForget: (() -> Void)?
    var onShowStateLegend: (() -> Void)?
    var onStateLegendCancelled: (() -> Void)?
    var onGuidanceDismissed: (() -> Void)?

    private let chip = NSButton()
    private let sheet = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Codex")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let privacyLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(
        title: L10n.text("다시 시도", "Try again"),
        target: nil,
        action: nil
    )
    private let removeHookButton = NSButton(
        title: L10n.text("현재 hook 제거", "Remove current hook"),
        target: nil,
        action: nil
    )
    private let forgetButton = NSButton(
        title: L10n.text("연결 기록 지우기", "Forget history"),
        target: nil,
        action: nil
    )
    private let secondaryActions = NSStackView()
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private let stateLegendHelpButton = NSButton()
    private let stateLegend = NSVisualEffectView()
    private let stateLegendTitle = NSTextField(
        labelWithString: L10n.text("장면을 보는 법", "How to read the scene")
    )
    private let activeLegendLabel = NSTextField(
        labelWithString: L10n.text("움직임 · 활동 중", "Movement · Active")
    )
    private let attentionLegendLabel = NSTextField(
        labelWithString: L10n.text("고리 · 확인 필요", "Ring · Needs attention")
    )
    private let turnEndedLegendLabel = NSTextField(
        labelWithString: L10n.text("바깥으로 번지는 파동 · 턴 종료", "Outward ripple · Turn ended")
    )
    private let activeLegendSignal = StateLegendSignalView(kind: .movement)
    private let attentionLegendSignal = StateLegendSignalView(kind: .attention)
    private let turnEndedLegendSignal = StateLegendSignalView(kind: .turnEnded)
    private var stateLegendDismissTimer: Timer?
    private var stateLegendCompletion: (() -> Void)?
    private var stateLegendReduceMotion = false
    private var hasResolvedInitialVisibility = false
    private var increaseContrast = false
    private var diagnostics = ConnectionDiagnostics(
        receiverReady: false,
        lastEventAt: nil,
        previouslyConfirmedAt: nil,
        rejectedEventCount: 0,
        receiverError: nil,
        hookInstallationState: .checking,
        inlineHooksPresent: false,
        managedHookPresent: false,
        hookRuntimeStatus: .checking,
        runtimeProblemEvents: [],
        reviewLaunchState: .idle,
        hookProblemOverridesHistory: false,
        currentHookConfirmedAt: nil,
        hasSeparateConnectionConfirmation: false
    )
    private(set) var connectionStatusKindForE2E = ConnectionStatusKind.checking.rawValue

    var isGuidanceVisible: Bool { !sheet.isHidden }
    var isActionVisibleForE2E: Bool { !actionButton.isHidden }
    var isSeparateForgetVisibleForE2E: Bool { !forgetButton.isHidden }
    var inlineAdvisoryVisibleForE2E: Bool {
        chip.title.contains("◇")
            && (chip.accessibilityValue() as? String)?.contains("hook") == true
    }
    func matchesConnectionPresentationForE2E(
        _ presentation: ConnectionStatusPresentation
    ) -> Bool {
        connectionStatusKindForE2E == presentation.kind.rawValue
            && chip.title == presentation.chipTitle
            && chip.accessibilityValue() as? String == presentation.accessibilityValue
    }
    var isStateLegendHelpIconForE2E: Bool {
        stateLegendHelpButton.title.isEmpty
            && stateLegendHelpButton.image != nil
            && stateLegendHelpButton.imagePosition == .imageOnly
            && stateLegendHelpButton.accessibilityRole() == .button
            && stateLegendHelpButton.action == #selector(showStateLegendHelp)
            && stateLegendHelpButton.toolTip
                == L10n.text("장면을 보는 법", "How to read the scene")
            && stateLegendHelpButton.accessibilityLabel()
                == L10n.text("장면을 보는 법", "How to read the scene")
            && stateLegendHelpButton.accessibilityHelp()
                == stateGrammarAccessibilityHelp
    }
    var isStateLegendVisible: Bool { !stateLegend.isHidden }
    var isStateLegendAccessible: Bool {
        stateLegend.isAccessibilityElement()
            && stateLegend.accessibilityRole() == .group
            && [activeLegendLabel, attentionLegendLabel, turnEndedLegendLabel]
                .allSatisfy {
                    $0.isAccessibilityElement() && $0.accessibilityRole() == .staticText
                }
    }
    /// Confirms the visible legend's real label, chevron path, and layer
    /// animations without including any observed agent data in E2E output.
    var isReduceMotionLegendStaticForE2E: Bool {
        let expectedLabel = L10n.text(
            "꺾쇠 · 활동 중",
            "Chevron · Active"
        )
        return stateLegendReduceMotion
            && !stateLegend.isHidden
            && activeLegendLabel.stringValue == expectedLabel
            && activeLegendLabel.accessibilityLabel() == expectedLabel
            && activeLegendSignal.isStaticChevronForE2E
            && attentionLegendSignal.hasNoAnimationsForE2E
            && turnEndedLegendSignal.hasNoAnimationsForE2E
            && (stateLegend.layer?.animationKeys()?.isEmpty ?? true)
    }
    var hooksCommandCopiedForE2E: Bool {
        hooksPasteboard.string(forType: .string) == "/hooks"
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureChip()
        configureSheet()
        configureStateLegend()
        update(diagnostics, now: .now)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ next: ConnectionDiagnostics, now: Date) {
        let previousGuidanceProblem = diagnostics.guidanceProblem
        let nextGuidanceProblem = next.guidanceProblem
        let receivedFirstEvent = diagnostics.lastEventAt == nil && next.lastEventAt != nil
        let recovered = diagnostics.rejectedEventCount > 0
            && next.rejectedEventCount == 0
            && next.lastEventAt != nil
        let becameRuntimeReady = diagnostics.hookRuntimeStatus != .ready
            && next.hookRuntimeStatus == .ready
            && next.hookInstallationState == .installed
            && next.managedHookPresent
        diagnostics = next
        if !hasResolvedInitialVisibility, next.hookInstallationState != .checking {
            hasResolvedInitialVisibility = true
            // A receiver problem can appear before the slower first hook
            // status. If the user already dismissed that same problem, the
            // status result must not open it again merely to resolve startup.
            if nextGuidanceProblem == nil {
                setGuidanceVisible(next.needsOnboarding)
            }
        }
        if (receivedFirstEvent || recovered),
            !next.hookProblemShouldLead,
            !next.runtimeProblemShouldLead
        {
            setGuidanceVisible(false)
        }
        if becameRuntimeReady,
            !next.hasConfirmedConnection,
            !next.hookProblemShouldLead,
            !next.runtimeProblemShouldLead
        {
            setGuidanceVisible(true)
        }
        if nextGuidanceProblem != nil,
            nextGuidanceProblem != previousGuidanceProblem
        {
            setGuidanceVisible(true)
        }
        updateChip(now: now)
        updateSheet()
    }

    func setIncreaseContrast(_ isEnabled: Bool) {
        guard increaseContrast != isEnabled else { return }
        increaseContrast = isEnabled
        updateContrastAppearance()
        if isStateLegendVisible {
            updateStateLegendSignals(reduceMotion: stateLegendReduceMotion)
        }
    }

    func setReduceMotion(_ isEnabled: Bool) {
        guard stateLegendReduceMotion != isEnabled else { return }
        stateLegendReduceMotion = isEnabled
        guard isStateLegendVisible else { return }
        if isEnabled {
            stateLegend.layer?.removeAllAnimations()
            stateLegend.alphaValue = 1
        }
        updateStateLegendSignals(reduceMotion: isEnabled)
    }

    @discardableResult
    func presentStateLegend(
        duration: TimeInterval,
        reduceMotion: Bool,
        onCompleted: @escaping () -> Void
    ) -> Bool {
        guard !isGuidanceVisible else { return false }
        cancelStateLegend()

        stateLegendReduceMotion = reduceMotion
        stateLegendCompletion = onCompleted
        updateStateLegendSignals(reduceMotion: reduceMotion)
        stateLegend.alphaValue = reduceMotion ? 1 : 0
        stateLegend.isHidden = false
        NSAccessibility.post(
            element: stateLegend,
            notification: .announcementRequested,
            userInfo: [
                .announcement: stateGrammarAccessibilityHelp,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                stateLegend.animator().alphaValue = 1
            }
        }

        let timer = Timer(
            timeInterval: max(0.001, duration),
            target: self,
            selector: #selector(completeStateLegend),
            userInfo: nil,
            repeats: false
        )
        stateLegendDismissTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    func cancelStateLegend() {
        let wasActive = isStateLegendVisible || stateLegendCompletion != nil
        stateLegendDismissTimer?.invalidate()
        stateLegendDismissTimer = nil
        stateLegendCompletion = nil
        stateLegend.layer?.removeAllAnimations()
        stateLegend.alphaValue = 1
        stateLegend.isHidden = true
        stopStateLegendAnimations()
        if wasActive {
            onStateLegendCancelled?()
        }
    }

    private func configureChip() {
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.isBordered = false
        chip.font = .systemFont(ofSize: 10.5, weight: .medium)
        chip.contentTintColor = .white.withAlphaComponent(0.68)
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        chip.layer?.cornerRadius = 12
        chip.target = self
        chip.action = #selector(toggleSheet)
        chip.setAccessibilityLabel(L10n.text("Codex 연결 상태", "Codex connection status"))
        chip.toolTip = L10n.text(
            "Codex 연결 상태와 설정",
            "Codex connection status and settings"
        )
        chip.setAccessibilityHelp(
            L10n.text(
                "연결 상태, 연결 시작과 연결 해제 작업을 엽니다.",
                "Opens connection status, setup, and disconnect actions."
            )
        )
        addSubview(chip)

        stateLegendHelpButton.translatesAutoresizingMaskIntoConstraints = false
        stateLegendHelpButton.title = ""
        stateLegendHelpButton.image = NSImage(
            systemSymbolName: "questionmark.circle",
            accessibilityDescription: nil
        )
        stateLegendHelpButton.imagePosition = .imageOnly
        stateLegendHelpButton.imageScaling = .scaleProportionallyDown
        stateLegendHelpButton.isBordered = false
        stateLegendHelpButton.target = self
        stateLegendHelpButton.action = #selector(showStateLegendHelp)
        stateLegendHelpButton.setAccessibilityElement(true)
        stateLegendHelpButton.setAccessibilityRole(.button)
        stateLegendHelpButton.toolTip = L10n.text(
            "장면을 보는 법",
            "How to read the scene"
        )
        stateLegendHelpButton.setAccessibilityLabel(
            L10n.text("장면을 보는 법", "How to read the scene")
        )
        stateLegendHelpButton.setAccessibilityHelp(stateGrammarAccessibilityHelp)
        addSubview(stateLegendHelpButton)
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            chip.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            chip.heightAnchor.constraint(equalToConstant: 25),
            chip.trailingAnchor.constraint(
                lessThanOrEqualTo: stateLegendHelpButton.leadingAnchor,
                constant: -8
            ),
            stateLegendHelpButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -11
            ),
            stateLegendHelpButton.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            stateLegendHelpButton.widthAnchor.constraint(equalToConstant: 28),
            stateLegendHelpButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func configureSheet() {
        sheet.translatesAutoresizingMaskIntoConstraints = false
        sheet.material = .hudWindow
        sheet.blendingMode = .withinWindow
        sheet.state = .active
        sheet.wantsLayer = true
        sheet.layer?.cornerRadius = 15
        addSubview(sheet)

        [
            titleLabel,
            bodyLabel,
            privacyLabel,
            actionButton,
            secondaryActions,
            closeButton,
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            sheet.addSubview($0)
        }
        configureSheetContent()
        NSLayoutConstraint.activate(sheetConstraints())
        updateContrastAppearance()
    }

    private func configureStateLegend() {
        stateLegend.translatesAutoresizingMaskIntoConstraints = false
        stateLegend.material = .hudWindow
        stateLegend.blendingMode = .withinWindow
        stateLegend.state = .active
        stateLegend.wantsLayer = true
        stateLegend.layer?.cornerRadius = 14
        stateLegend.isHidden = true
        stateLegend.setAccessibilityElement(true)
        stateLegend.setAccessibilityRole(.group)
        stateLegend.setAccessibilityLabel(
            L10n.text("agent-meong 상태 문법", "agent-meong state grammar")
        )
        stateLegend.setAccessibilityHelp(stateGrammarAccessibilityHelp)
        addSubview(stateLegend)

        stateLegendTitle.font = .systemFont(ofSize: 11.5, weight: .semibold)
        let rows = [
            stateLegendRow(signal: activeLegendSignal, label: activeLegendLabel),
            stateLegendRow(signal: attentionLegendSignal, label: attentionLegendLabel),
            stateLegendRow(signal: turnEndedLegendSignal, label: turnEndedLegendLabel),
        ]
        let stack = NSStackView(views: rows)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stateLegendTitle.translatesAutoresizingMaskIntoConstraints = false
        stateLegend.addSubview(stateLegendTitle)
        stateLegend.addSubview(stack)

        NSLayoutConstraint.activate([
            stateLegend.centerXAnchor.constraint(equalTo: centerXAnchor),
            stateLegend.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            stateLegend.widthAnchor.constraint(equalToConstant: 286),
            stateLegend.heightAnchor.constraint(equalToConstant: 108),
            stateLegendTitle.leadingAnchor.constraint(equalTo: stateLegend.leadingAnchor, constant: 15),
            stateLegendTitle.topAnchor.constraint(equalTo: stateLegend.topAnchor, constant: 11),
            stateLegendTitle.trailingAnchor.constraint(
                lessThanOrEqualTo: stateLegend.trailingAnchor,
                constant: -15
            ),
            stack.leadingAnchor.constraint(equalTo: stateLegendTitle.leadingAnchor),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: stateLegend.trailingAnchor,
                constant: -15
            ),
            stack.topAnchor.constraint(equalTo: stateLegendTitle.bottomAnchor, constant: 5),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: stateLegend.bottomAnchor, constant: -9),
        ])
        updateContrastAppearance()
    }

    private func stateLegendRow(
        signal: StateLegendSignalView,
        label: NSTextField
    ) -> NSStackView {
        signal.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.setAccessibilityElement(true)
        label.setAccessibilityRole(.staticText)
        label.setAccessibilityLabel(label.stringValue)
        let row = NSStackView(views: [signal, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        NSLayoutConstraint.activate([
            signal.widthAnchor.constraint(equalToConstant: 20),
            signal.heightAnchor.constraint(equalToConstant: 20),
            row.heightAnchor.constraint(equalToConstant: 20),
        ])
        return row
    }

    private var stateGrammarAccessibilityHelp: String {
        L10n.text(
            "움직임은 활동 중이며 동작 줄이기에서는 꺾쇠 표식으로 대신합니다. 고리는 확인 필요, 바깥으로 번지는 파동은 턴 종료를 뜻합니다.",
            "Movement means active and becomes a chevron marker with Reduce Motion. A ring means needs attention, and an outward ripple means the turn ended."
        )
    }

    private func updateStateLegendSignals(reduceMotion: Bool) {
        activeLegendLabel.stringValue = reduceMotion
            ? L10n.text("꺾쇠 · 활동 중", "Chevron · Active")
            : L10n.text("움직임 · 활동 중", "Movement · Active")
        activeLegendLabel.setAccessibilityLabel(activeLegendLabel.stringValue)
        [activeLegendSignal, attentionLegendSignal, turnEndedLegendSignal].forEach {
            $0.updatePresentation(
                reduceMotion: reduceMotion,
                increaseContrast: increaseContrast
            )
        }
    }

    private func stopStateLegendAnimations() {
        [activeLegendSignal, attentionLegendSignal, turnEndedLegendSignal].forEach {
            $0.stopAnimations()
        }
    }

    @objc private func completeStateLegend() {
        guard isStateLegendVisible else { return }
        stateLegendDismissTimer?.invalidate()
        stateLegendDismissTimer = nil
        stateLegend.isHidden = true
        stopStateLegendAnimations()
        let completion = stateLegendCompletion
        stateLegendCompletion = nil
        completion?()
    }

    private func configureSheetContent() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.maximumNumberOfLines = 15
        privacyLabel.font = .systemFont(ofSize: 10.5)
        privacyLabel.maximumNumberOfLines = 3
        actionButton.bezelStyle = .roundRect
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(performAction)
        removeHookButton.isBordered = false
        removeHookButton.controlSize = .small
        removeHookButton.target = self
        removeHookButton.action = #selector(removeCurrentHook)
        removeHookButton.setAccessibilityLabel(
            L10n.text("현재 Codex hook 제거", "Remove the current Codex hook")
        )
        forgetButton.isBordered = false
        forgetButton.controlSize = .small
        forgetButton.target = self
        forgetButton.action = #selector(forgetConnection)
        forgetButton.setAccessibilityLabel(
            L10n.text("Codex 연결 기록 지우기", "Forget Codex connection history")
        )
        secondaryActions.orientation = .horizontal
        secondaryActions.alignment = .centerY
        secondaryActions.spacing = 8
        secondaryActions.addArrangedSubview(removeHookButton)
        secondaryActions.addArrangedSubview(forgetButton)
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 16, weight: .light)
        closeButton.target = self
        closeButton.action = #selector(closeSheet)
        closeButton.setAccessibilityLabel(
            L10n.text("연결 안내 닫기", "Close connection guidance")
        )
    }

    private func sheetConstraints() -> [NSLayoutConstraint] {
        [
            sheet.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            sheet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            sheet.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            sheet.heightAnchor.constraint(equalToConstant: 300),
            titleLabel.leadingAnchor.constraint(equalTo: sheet.leadingAnchor, constant: 18),
            titleLabel.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 15),
            closeButton.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -18),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            privacyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            privacyLabel.trailingAnchor.constraint(equalTo: bodyLabel.trailingAnchor),
            privacyLabel.bottomAnchor.constraint(equalTo: sheet.bottomAnchor, constant: -14),
            actionButton.trailingAnchor.constraint(equalTo: bodyLabel.trailingAnchor),
            actionButton.bottomAnchor.constraint(equalTo: privacyLabel.topAnchor, constant: -8),
            secondaryActions.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            secondaryActions.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
            secondaryActions.trailingAnchor.constraint(
                lessThanOrEqualTo: actionButton.leadingAnchor,
                constant: -8
            ),
        ]
    }

    private func updateChip(now: Date) {
        let presentation = ConnectionStatusPresentation.make(
            diagnostics: diagnostics,
            now: now
        )
        connectionStatusKindForE2E = presentation.kind.rawValue
        chip.title = presentation.chipTitle
        chip.setAccessibilityValue(presentation.accessibilityValue)
    }

    private func updateSheet() {
        updateActionButtons()
        actionButton.setAccessibilityLabel(actionButton.title)
        if let error = diagnostics.receiverError {
            titleLabel.stringValue = L10n.text(
                "로컬 수신기를 열지 못했어요",
                "Could not open the local receiver"
            )
            bodyLabel.stringValue = L10n.text(
                "Codex 이벤트를 받을 수 없습니다.\n\n\(error)",
                "agent-meong cannot receive Codex events.\n\n\(error)"
            )
        } else if diagnostics.rejectedEventCount > 0 {
            titleLabel.stringValue = L10n.text(
                "Codex 이벤트 형식이 맞지 않아요",
                "The Codex event format does not match"
            )
            bodyLabel.stringValue = L10n.text(
                "장면은 변경하지 않았습니다.\nadapter와 앱 버전을 확인하세요.\n\n거절된 이벤트 · \(diagnostics.rejectedEventCount)개",
                "The scene was left unchanged.\nCheck the adapter and app versions.\n\nRejected events · \(diagnostics.rejectedEventCount)"
            )
        } else if !diagnostics.receiverReady {
            titleLabel.stringValue = L10n.text(
                "로컬 수신기를 준비하고 있어요",
                "Preparing the local receiver"
            )
            bodyLabel.stringValue = L10n.text(
                "Codex 이벤트를 받을 준비가 끝날 때까지 잠시 기다려 주세요.",
                "Please wait while agent-meong gets ready to receive Codex events."
            )
        } else if diagnostics.hookProblemShouldLead {
            updateInstallationSheet()
        } else if diagnostics.runtimeProblemShouldLead {
            updateRuntimeSheet()
        } else if diagnostics.hasConfirmedConnection, let date = diagnostics.lastEventAt {
            titleLabel.stringValue = L10n.text(
                diagnostics.hasOnlySeparateConnection
                    ? "별도 CODEX_HOME 연결됨"
                    : "OpenAI Codex 연결됨",
                diagnostics.hasOnlySeparateConnection
                    ? "Separate CODEX_HOME connected"
                    : "OpenAI Codex connected"
            )
            setInstallationBody(
                L10n.text(
                    "● 로컬 수신기 준비됨\n● 이벤트 수신 확인됨\n마지막 이벤트 · \(L10n.time(date))\(secondaryHookStatusNote)",
                    "● Local receiver ready\n● Event receipt confirmed\nLast event · \(L10n.time(date))\(secondaryHookStatusNote)"
                )
            )
        } else if diagnostics.hasConfirmedConnection,
            let date = diagnostics.previouslyConfirmedAt,
            !diagnostics.hookProblemOverridesHistory
        {
            titleLabel.stringValue = L10n.text(
                diagnostics.hasOnlySeparateConnection
                    ? "별도 CODEX_HOME 이벤트 대기 중"
                    : "Codex 이벤트 대기 중",
                diagnostics.hasOnlySeparateConnection
                    ? "Waiting for a separate CODEX_HOME event"
                    : "Waiting for a Codex event"
            )
            setInstallationBody(
                L10n.text(
                    "● 이전 실제 이벤트 확인됨\n○ 이번 실행 이벤트 대기 중\n마지막 확인 · \(L10n.time(date))\(secondaryHookStatusNote)",
                    "● Earlier real event confirmed\n○ Waiting for an event in this run\nLast confirmed · \(L10n.time(date))\(secondaryHookStatusNote)"
                )
            )
        } else {
            updateInstallationSheet()
        }
        privacyLabel.stringValue = L10n.text(
            "관찰: 작업·도구 범주·승인·서브에이전트·종료\n저장·로그·전송 안 함: 프롬프트·응답·명령·파일 경로·tool input/output",
            "Observes: work, tool category, approval, subagents, finish\nNever stores, logs, or sends: prompts, responses, commands, paths, tool input/output"
        )
    }

    private func updateContrastAppearance() {
        let foregroundAlpha: CGFloat = increaseContrast ? 1 : 0.68
        chip.contentTintColor = .white.withAlphaComponent(foregroundAlpha)
        stateLegendHelpButton.contentTintColor = .white.withAlphaComponent(foregroundAlpha)
        chip.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(increaseContrast ? 0.82 : 0.22)
            .cgColor
        chip.layer?.borderColor = NSColor.white
            .withAlphaComponent(increaseContrast ? 0.86 : 0)
            .cgColor
        chip.layer?.borderWidth = increaseContrast ? 1 : 0

        sheet.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(increaseContrast ? 0.72 : 0)
            .cgColor
        sheet.layer?.borderColor = NSColor.white
            .withAlphaComponent(increaseContrast ? 0.72 : 0)
            .cgColor
        sheet.layer?.borderWidth = increaseContrast ? 1 : 0
        titleLabel.textColor = .white.withAlphaComponent(increaseContrast ? 1 : 0.88)
        bodyLabel.textColor = .white.withAlphaComponent(increaseContrast ? 0.96 : 0.74)
        privacyLabel.textColor = .white.withAlphaComponent(increaseContrast ? 0.90 : 0.60)
        removeHookButton.contentTintColor = .white.withAlphaComponent(
            increaseContrast ? 0.94 : 0.55
        )
        forgetButton.contentTintColor = .white.withAlphaComponent(
            increaseContrast ? 0.94 : 0.55
        )
        closeButton.contentTintColor = .white.withAlphaComponent(increaseContrast ? 0.94 : 0.45)

        stateLegend.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(increaseContrast ? 0.78 : 0)
            .cgColor
        stateLegend.layer?.borderColor = NSColor.white
            .withAlphaComponent(increaseContrast ? 0.78 : 0)
            .cgColor
        stateLegend.layer?.borderWidth = increaseContrast ? 1 : 0
        stateLegendTitle.textColor = .white.withAlphaComponent(increaseContrast ? 1 : 0.90)
        [activeLegendLabel, attentionLegendLabel, turnEndedLegendLabel].forEach {
            $0.textColor = .white.withAlphaComponent(increaseContrast ? 1 : 0.76)
        }
    }

    private func setInstallationBody(_ body: String) {
        var result = body
        if
            diagnostics.hookProblemShouldLead,
            diagnostics.lastEventAt != nil || diagnostics.previouslyConfirmedAt != nil
        {
            result += L10n.text(
                "\n\n기존 관찰 기록과 장면은 현재 기본 hook 작업과 별도로 유지됩니다.",
                "\n\nExisting observation history and the scene stay separate from this default-hook action."
            )
        }
        if diagnostics.inlineHooksPresent {
            result += L10n.text(
                "\n\n참고: config.toml inline hook과 hooks.json이 함께 로드되어 Codex가 시작 경고를 표시합니다.",
                "\n\nNote: Codex loads both config.toml inline hooks and hooks.json, so it shows a startup warning."
            )
        }
        bodyLabel.stringValue = result
    }

    private var secondaryHookStatusNote: String {
        if diagnostics.hasOnlySeparateConnection {
            return L10n.text(
                "\n별도 CODEX_HOME은 연결되어 있고 기본 ~/.codex는 아직 연결되지 않았습니다.",
                "\nA separate CODEX_HOME is connected; the default ~/.codex is not connected yet."
            )
        }
        if diagnostics.hasSeparateConnectionConfirmation {
            return L10n.text(
                "\n참고: 기본 hook을 제거해도 별도 연결의 장면과 기록은 남습니다.",
                "\nNote: removing the default hook keeps separate connections and their scene state."
            )
        }
        return L10n.text(
            "\n참고: 기본 hook을 제거하면 그 연결의 장면과 기록만 지웁니다.",
            "\nNote: removing the default hook clears only that connection's scene and history."
        )
    }

    @objc private func toggleSheet() {
        setGuidanceVisible(sheet.isHidden)
    }

    @objc private func showStateLegendHelp() {
        setGuidanceVisible(false, notifyDismissal: false)
        onShowStateLegend?()
    }

    @objc private func closeSheet() {
        setGuidanceVisible(false)
    }

    private func setGuidanceVisible(
        _ isVisible: Bool,
        notifyDismissal: Bool = true
    ) {
        let wasVisible = !sheet.isHidden
        if isVisible {
            cancelStateLegend()
        }
        sheet.isHidden = !isVisible
        if wasVisible, !isVisible, notifyDismissal {
            onGuidanceDismissed?()
        }
    }

    private func updateActionButtons() {
        let canRemoveCurrentHook = diagnostics.managedHookPresent
            && diagnostics.hookInstallationState != .checking
            && diagnostics.hookInstallationState != .newerVersion
        removeHookButton.isHidden = !canRemoveCurrentHook
        let keepsSeparateConnection = diagnostics.hasSeparateConnectionConfirmation
        removeHookButton.title = keepsSeparateConnection
            ? L10n.text("기본 hook 제거", "Remove default hook")
            : L10n.text("연결 해제", "Disconnect")
        removeHookButton.setAccessibilityLabel(
            keepsSeparateConnection
                ? L10n.text("기본 Codex hook 제거", "Remove the default Codex hook")
                : L10n.text("현재 Codex 연결 해제", "Disconnect the current Codex connection")
        )
        removeHookButton.setAccessibilityHelp(
            keepsSeparateConnection
                ? L10n.text(
                    "기본 hook과 그 연결의 상태만 제거하고 별도 연결의 기록과 장면은 유지합니다.",
                    "Removes the default hook and its state while keeping separate connection history and scene state."
                )
                : L10n.text(
                    "기본 hook과 그 연결의 장면 및 재시작 체크포인트를 지웁니다.",
                    "Removes the default hook and clears its scene and restart checkpoint state."
                )
        )

        let canForgetSeparateConnection = diagnostics.hasSeparateConnectionConfirmation
        forgetButton.isHidden = !canForgetSeparateConnection
        forgetButton.title = L10n.text("별도 기록 지우기", "Forget separate history")
        forgetButton.setAccessibilityLabel(
            L10n.text(
                "별도 Codex 연결 기록 지우기",
                "Forget separate Codex connection history"
            )
        )
        forgetButton.setAccessibilityHelp(
            L10n.text(
                "hook은 제거하지 않고 별도 연결의 기록, 오브젝트와 종료 흔적만 지웁니다.",
                "Keeps hooks installed and clears only separate connection history, objects, and end receipts."
            )
        )
        switch diagnostics.primaryAction {
        case .hidden:
            actionButton.isHidden = true
        case .retryReceiver:
            actionButton.title = L10n.text("다시 시도", "Try again")
            actionButton.isHidden = false
        case .connect:
            actionButton.title = L10n.text(
                "연결 시작",
                "Connect"
            )
            actionButton.isHidden = false
        case .repair:
            actionButton.title = L10n.text(
                "연결 복구",
                "Repair connection"
            )
            actionButton.isHidden = false
        case .refreshStatus:
            actionButton.title = L10n.text("다시 확인", "Check again")
            actionButton.isHidden = false
        case .review:
            actionButton.title = L10n.text(
                "Codex 검토 열기",
                "Open Codex review"
            )
            actionButton.isHidden = false
        }
    }

    private func updateInstallationSheet() {
        switch diagnostics.hookInstallationState {
        case .checking:
            titleLabel.stringValue = L10n.text(
                "Codex 연결을 확인하고 있어요",
                "Checking the Codex connection"
            )
            setInstallationBody(
                L10n.text(
                    "● 로컬 수신기 준비됨\n○ 사용자 연결 확인 중",
                    "● Local receiver ready\n○ Checking the user connection"
                )
            )
        case .notInstalled:
            titleLabel.stringValue = L10n.text("Codex 연결", "Connect Codex")
            setInstallationBody(
                L10n.text(
                    "Codex App · ChatGPT 안의 Codex · Codex CLI\n\n‘연결 시작’을 누르면 현재 사용자 Codex home에\nadapter와 lifecycle hook을 설치합니다.\n기존 설정은 그대로 보존합니다.\n\n그다음 앱이 새 Codex CLI와 /hooks 검토를 준비합니다.\n현재 정의가 바뀌지 않는 동안 사용자가 직접 하는 일은\nCodex의 보안 승인 한 번뿐입니다.",
                    "Codex App · Codex in ChatGPT · Codex CLI\n\nConnect installs the adapter and lifecycle hooks in\nthe current user's Codex home without replacing\nexisting settings.\n\nagent-meong then prepares a fresh Codex CLI and /hooks.\nWhile this definition stays unchanged, the only manual\nstep is Codex's security review."
                )
            )
        case .installed:
            if let date = diagnostics.currentHookConfirmedAt
            {
                titleLabel.stringValue = L10n.text(
                    "Codex 이벤트 대기 중",
                    "Waiting for a Codex event"
                )
                setInstallationBody(
                    L10n.text(
                        "● 사용자 hook 설치됨\n● 이전 실제 이벤트 확인됨\n○ 이번 실행 이벤트 대기 중\n\n마지막 확인 · \(L10n.time(date))\n같은 Codex home을 쓰는 App과 CLI에 적용됩니다.",
                        "● User hooks installed\n● Earlier real event confirmed\n○ Waiting for an event in this run\n\nLast confirmed · \(L10n.time(date))\nApplies to App and CLI using the same Codex home."
                    )
                )
            } else {
                updateInstalledButUnconfirmedSheet()
            }
        case .needsRepair:
            titleLabel.stringValue = L10n.text(
                "Codex 연결 복구가 필요해요",
                "The Codex connection needs repair"
            )
            setInstallationBody(
                L10n.text(
                    "● 로컬 수신기 준비됨\n○ 사용자 hook 또는 adapter 갱신 필요\n\n기존 Codex 설정은 보존됩니다.\n아래 버튼으로 agent-meong 항목만 복구한 뒤\nCodex App과 CLI를 완전히 종료하고 다시 여세요.",
                    "● Local receiver ready\n○ User hooks or adapter need an update\n\nExisting Codex settings are preserved.\nRepair only agent-meong entries below, then fully\nquit and reopen Codex App and CLI."
                )
            )
        case .invalidConfiguration:
            titleLabel.stringValue = L10n.text(
                "Codex hook 설정을 확인하세요",
                "Check the Codex hook configuration"
            )
            setInstallationBody(
                L10n.text(
                    "현재 Codex home의 hooks.json을 읽을 수 없습니다.\n기존 파일은 변경하지 않았습니다.\n\nJSON 형식을 수정한 뒤 다시 확인을 누르세요.",
                    "The current Codex home's hooks.json cannot be read.\nThe existing file was not changed.\n\nFix the JSON, then choose Check again."
                )
            )
        case .hooksDisabled:
            titleLabel.stringValue = L10n.text(
                "Codex hooks가 꺼져 있어요",
                "Codex hooks are disabled"
            )
            setInstallationBody(
                L10n.text(
                    "Codex 설정 또는 관리 정책의 [features]\nhooks = false로 lifecycle hook이 꺼져 있습니다.\n\nhooks를 켠 뒤 다시 확인을 누르세요.\nagent-meong은 이 설정을 변경하지 않습니다.",
                    "[features] hooks = false in Codex settings or policy\ndisables lifecycle hooks.\n\nEnable hooks, then choose Check again.\nagent-meong does not change this setting."
                )
            )
        case .managedHooksOnly:
            titleLabel.stringValue = L10n.text(
                "관리형 hook만 허용되어 있어요",
                "Only managed hooks are allowed"
            )
            setInstallationBody(
                L10n.text(
                    "requirements.toml 또는 관리 정책의\nallow_managed_hooks_only = true가 사용자\ncommand hook 실행을 막습니다.\n\n관리자 정책을 변경한 뒤 다시 확인을 누르세요.",
                    "allow_managed_hooks_only = true in requirements.toml\nor managed policy blocks user command hooks.\n\nAsk an administrator to change the policy,\nthen choose Check again."
                )
            )
        case .newerVersion:
            titleLabel.stringValue = L10n.text(
                "더 새로운 연결이 설치되어 있어요",
                "A newer connection is installed"
            )
            setInstallationBody(
                L10n.text(
                    "현재 앱보다 새로운 agent-meong hook을 발견했습니다.\n\n안전을 위해 변경하거나 제거하지 않았습니다.\nagent-meong을 업데이트한 뒤 다시 확인하세요.",
                    "A newer agent-meong hook was found.\n\nIt was not changed or removed for safety.\nUpdate agent-meong, then check again."
                )
            )
        case let .unavailable(message):
            titleLabel.stringValue = L10n.text(
                "Codex 연결 상태를 확인하지 못했어요",
                "Could not check the Codex connection"
            )
            setInstallationBody(message)
        }
    }

    private func updateInstalledButUnconfirmedSheet() {
        if diagnostics.hookRuntimeStatus == .ready {
            titleLabel.stringValue = L10n.text(
                "Codex 연결 준비 완료",
                "Codex is ready"
            )
            setInstallationBody(
                L10n.text(
                    "● lifecycle command hook 설치됨\n● Codex에서 7개 handler 활성·신뢰 확인됨\n○ 첫 agent 활동 대기 중\n\n방금 연 CLI에서 요청을 보내 먼저 확인하세요.\n이전에 열어 둔 Codex는 완전히 종료하고 다시 여세요.",
                    "● Lifecycle command hooks installed\n● All 7 handlers are enabled and trusted in Codex\n○ Waiting for the first agent activity\n\nSend a request in the CLI just opened for the first check.\nFully quit and reopen Codex instances left open earlier."
                )
            )
            return
        }

        if diagnostics.hookRuntimeStatus == .unavailable {
            titleLabel.stringValue = L10n.text(
                "Codex 상태를 다시 확인해 주세요",
                "Check the Codex status again"
            )
            setInstallationBody(
                L10n.text(
                    "● lifecycle command hook 설치됨\n○ 활성·신뢰 상태를 이번에는 읽지 못함\n\n설정이나 승인 상태를 미승인으로 간주하지 않았습니다.\n‘다시 확인’을 누르거나 Codex에서 새 작업을 시작해 보세요.",
                    "● Lifecycle command hooks installed\n○ Enabled and trusted state could not be read this time\n\nagent-meong did not treat this as a missing approval.\nChoose Check again or start new work in Codex."
                )
            )
            return
        }

        titleLabel.stringValue = L10n.text(
            "현재 연결을 Codex에서 승인하세요",
            "Approve this connection in Codex"
        )
        setInstallationBody(reviewInstructions)
    }

    private func updateRuntimeSheet() {
        switch diagnostics.hookRuntimeStatus {
        case .disabled:
            titleLabel.stringValue = L10n.text(
                "일부 Codex hook이 꺼져 있어요",
                "Some Codex hooks are disabled"
            )
            let events = runtimeProblemEventsLabel
            setInstallationBody(
                L10n.text(
                    "Codex가 agent-meong lifecycle handler를 실행하지 않습니다.\n꺼진 이벤트 · \(events)\n\n\(reviewInstructions)",
                    "Codex will not run some agent-meong lifecycle handlers.\nDisabled events · \(events)\n\n\(reviewInstructions)"
                )
            )
        case .reviewRequired:
            titleLabel.stringValue = L10n.text(
                "Codex의 승인이 필요해요",
                "Codex approval is required"
            )
            setInstallationBody(reviewInstructions)
        case .checking, .ready, .unavailable:
            updateInstalledButUnconfirmedSheet()
        }
    }

    private var reviewInstructions: String {
        let firstStep: String = switch diagnostics.reviewLaunchState {
        case .idle:
            L10n.text(
                "‘Codex 검토 열기’를 누르면 새 CLI를 열고 /hooks를 복사합니다.",
                "Open Codex review starts a fresh CLI and copies /hooks."
            )
        case .opening:
            L10n.text(
                "새 Codex CLI를 여는 중입니다.",
                "Opening a fresh Codex CLI."
            )
        case .opened:
            L10n.text(
                "새 Codex CLI를 열고 /hooks를 복사했습니다.\nTerminal에서 ⌘V → Return을 누르세요.",
                "A fresh Codex CLI is open and /hooks is copied.\nIn Terminal, press ⌘V → Return."
            )
        case .failed:
            L10n.text(
                "Codex 실행 파일을 찾지 못했거나 Terminal을 열지 못했습니다.\nCodex를 설치·업데이트한 뒤 CLI를 열고 ⌘V → Return을 누르세요.",
                "Codex could not be found or Terminal could not be opened.\nInstall or update Codex, open its CLI, then press ⌘V → Return."
            )
        }
        return firstStep + L10n.text(
            "\n\nUser config에서 lifecycle event와 command를 확인하고\nstatus가 agent-meong activity [dev.ailab.agent-meong/v5]인\n7개 command handler만 활성화·신뢰하세요.\n승인 상태는 앱이 자동으로 다시 확인합니다.",
            "\n\nUnder User config, review the lifecycle events and commands.\nEnable and trust only the 7 command handlers whose status is\nagent-meong activity [dev.ailab.agent-meong/v5].\nagent-meong rechecks the approval state automatically."
        )
    }

    private var runtimeProblemEventsLabel: String {
        let labels = diagnostics.runtimeProblemEvents.map { event in
            switch event {
            case "userPromptSubmit", "UserPromptSubmit": "UserPromptSubmit"
            case "preToolUse", "PreToolUse": "PreToolUse"
            case "permissionRequest", "PermissionRequest": "PermissionRequest"
            case "postToolUse", "PostToolUse": "PostToolUse"
            case "subagentStart", "SubagentStart": "SubagentStart"
            case "subagentStop", "SubagentStop": "SubagentStop"
            case "stop", "Stop": "Stop"
            default: L10n.text("알 수 없음", "Unknown")
            }
        }
        return labels.isEmpty ? L10n.text("확인 필요", "Check /hooks") : labels.joined(separator: " · ")
    }

    @objc private func performAction() {
        switch diagnostics.primaryAction {
        case .retryReceiver:
            onRetry?()
        case .connect, .repair:
            onInstall?()
        case .refreshStatus:
            onRefreshHookStatus?()
        case .review:
            onReview?()
        case .hidden:
            break
        }
    }

    @objc private func removeCurrentHook() {
        guard confirmDisconnect() else { return }
        onUninstall?()
    }

    @objc private func forgetConnection() {
        guard confirmForgetSeparateHistory() else { return }
        onForget?()
    }

    private func confirmDisconnect() -> Bool {
        guard !isE2ERun else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(
            "현재 Codex 연결을 해제할까요?",
            "Disconnect the current Codex connection?"
        )
        alert.informativeText = L10n.text(
            "agent-meong 기본 hook과 이 연결의 오브젝트·종료 흔적·확인 기록을 지웁니다. 다른 hook과 별도 CODEX_HOME은 유지합니다.\n\n완료 후 열려 있던 Codex App과 CLI를 완전히 종료하고 다시 열어야 합니다.",
            "This removes the default agent-meong hook and this connection's objects, end receipts, and confirmation. Other hooks and custom CODEX_HOME connections remain.\n\nAfterward, fully quit and reopen running Codex App and CLI instances."
        )
        alert.addButton(withTitle: L10n.text("취소", "Cancel"))
        alert.addButton(withTitle: L10n.text("연결 해제", "Disconnect"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func confirmForgetSeparateHistory() -> Bool {
        guard !isE2ERun else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(
            "별도 연결 기록을 지울까요?",
            "Forget separate connection history?"
        )
        alert.informativeText = L10n.text(
            "별도 CODEX_HOME의 hook은 제거하지 않고 agent-meong에 남은 기록, 오브젝트와 종료 흔적만 지웁니다. 이 작업은 되돌릴 수 없습니다.",
            "This keeps custom CODEX_HOME hooks installed and removes only their agent-meong history, objects, and end receipts. This cannot be undone."
        )
        alert.addButton(withTitle: L10n.text("취소", "Cancel"))
        alert.addButton(withTitle: L10n.text("기록 지우기", "Forget history"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    private var isE2ERun: Bool {
        ProcessInfo.processInfo.environment["AGENT_MEONG_E2E_REPORT"] != nil
    }

    @discardableResult
    func copyHooksCommandAfterInstallation() -> Bool {
        copyHooksCommand()
    }

    @discardableResult
    private func copyHooksCommand() -> Bool {
        let pasteboard = hooksPasteboard
        pasteboard.clearContents()
        let copied = pasteboard.setString("/hooks", forType: .string)
        actionButton.title = copied
            ? L10n.text("/hooks 복사됨", "/hooks copied")
            : L10n.text("/hooks 복사", "Copy /hooks")
        actionButton.setAccessibilityLabel(actionButton.title)
        NSAccessibility.post(element: actionButton, notification: .valueChanged)
        return copied
    }

    func performPrimaryActionForE2E() {
        performAction()
    }

    func performSecondaryActionForE2E() {
        forgetConnection()
    }

    func performHookRemovalForE2E() {
        removeCurrentHook()
    }

    func performStateLegendHelpForE2E() {
        showStateLegendHelp()
    }

    func showGuidance() {
        setGuidanceVisible(true)
    }

    private var hooksPasteboard: NSPasteboard {
        guard ProcessInfo.processInfo.environment["AGENT_MEONG_E2E_REPORT"] != nil else {
            return .general
        }
        return NSPasteboard(name: .init("dev.ailab.agent-meong.e2e"))
    }
}
