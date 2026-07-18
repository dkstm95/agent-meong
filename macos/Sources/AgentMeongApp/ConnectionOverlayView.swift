import AppKit

private final class StateLegendSignalView: NSView {
    enum Kind {
        case movement
        case attention
        case turnEnded
        case uncertain
        case finished
        case completed
        case cancelled
        case failed
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
        case .uncertain:
            let segments = CGMutablePath()
            for index in 0..<6 {
                let start = CGFloat(index) * .pi / 3 + 0.10
                segments.addArc(
                    center: center,
                    radius: 6.5,
                    startAngle: start,
                    endAngle: start + 0.68,
                    clockwise: false
                )
            }
            primaryLayer.path = segments
            secondaryLayer.path = nil
        case .finished:
            let arc = CGMutablePath()
            arc.addArc(
                center: center,
                radius: 6.5,
                startAngle: .pi * 0.15,
                endAngle: .pi * 1.72,
                clockwise: false
            )
            primaryLayer.path = arc
            secondaryLayer.path = nil
        case .completed:
            primaryLayer.path = CGPath(
                ellipseIn: CGRect(x: center.x - 4.25, y: center.y - 4.25, width: 8.5, height: 8.5),
                transform: nil
            )
            secondaryLayer.path = CGPath(
                ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14),
                transform: nil
            )
            secondaryLayer.strokeColor = foreground.cgColor
        case .cancelled:
            let bar = CGMutablePath()
            bar.move(to: CGPoint(x: center.x - 7, y: center.y))
            bar.addLine(to: CGPoint(x: center.x + 7, y: center.y))
            primaryLayer.path = bar
            primaryLayer.lineWidth = increaseContrast ? 2.4 : 1.7
            secondaryLayer.path = nil
        case .failed:
            let diamond = CGMutablePath()
            diamond.move(to: CGPoint(x: center.x, y: center.y - 7))
            diamond.addLine(to: CGPoint(x: center.x + 7, y: center.y))
            diamond.addLine(to: CGPoint(x: center.x, y: center.y + 7))
            diamond.addLine(to: CGPoint(x: center.x - 7, y: center.y))
            diamond.closeSubpath()
            primaryLayer.path = diamond
            secondaryLayer.path = nil
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
        case .uncertain, .finished, .completed, .cancelled, .failed:
            break
        }
    }
}

enum StateLegendScope: Equatable {
    case essentials
    case allStates
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
    let otherPendingHookCount: Int?
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
                switch reviewLaunchState {
                case .opening:
                    return .hidden
                case .opened:
                    return .refreshStatus
                case .idle, .failed:
                    return .review
                }
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
    private let connectionProgressIndicator = NSProgressIndicator()
    private let bodyScrollView = NSScrollView()
    private let bodyTextView = NSTextView()
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
    private let uncertainLegendLabel = NSTextField(
        labelWithString: L10n.text("분절 고리 · 상태 불확실", "Segmented ring · Uncertain")
    )
    private let finishedLegendLabel = NSTextField(
        labelWithString: L10n.text("열린 호 · 종료", "Open arc · Finished")
    )
    private let completedLegendLabel = NSTextField(
        labelWithString: L10n.text("이중 후광 · 성공", "Double halo · Success")
    )
    private let cancelledLegendLabel = NSTextField(
        labelWithString: L10n.text("가로 막대 · 취소", "Horizontal bar · Cancelled")
    )
    private let failedLegendLabel = NSTextField(
        labelWithString: L10n.text("마름모 · 실패", "Diamond · Failed")
    )
    private let activeLegendSignal = StateLegendSignalView(kind: .movement)
    private let attentionLegendSignal = StateLegendSignalView(kind: .attention)
    private let turnEndedLegendSignal = StateLegendSignalView(kind: .turnEnded)
    private let uncertainLegendSignal = StateLegendSignalView(kind: .uncertain)
    private let finishedLegendSignal = StateLegendSignalView(kind: .finished)
    private let completedLegendSignal = StateLegendSignalView(kind: .completed)
    private let cancelledLegendSignal = StateLegendSignalView(kind: .cancelled)
    private let failedLegendSignal = StateLegendSignalView(kind: .failed)
    private let stateLegendStack = NSStackView()
    private var additionalStateLegendRows: [NSView] = []
    private var stateLegendHeightConstraint: NSLayoutConstraint?
    private var stateLegendDismissTimer: Timer?
    private var stateLegendCompletion: (() -> Void)?
    private var stateLegendReduceMotion = false
    private var stateLegendScope = StateLegendScope.essentials
    private var connectionProgressAnimating = false
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
        otherPendingHookCount: nil,
        reviewLaunchState: .idle,
        hookProblemOverridesHistory: false,
        currentHookConfirmedAt: nil,
        hasSeparateConnectionConfirmation: false
    )
    private(set) var connectionStatusKindForE2E = ConnectionStatusKind.checking.rawValue

    var isGuidanceVisible: Bool { !sheet.isHidden }
    var isActionVisibleForE2E: Bool { !actionButton.isHidden }
    var isConnectionProgressVisibleForE2E: Bool {
        !connectionProgressIndicator.isHidden
            && connectionProgressAnimating
    }
    var isGuidanceScrollableForE2E: Bool {
        layoutSubtreeIfNeeded()
        bodyScrollView.layoutSubtreeIfNeeded()
        guard
            bodyScrollView.documentView === bodyTextView,
            bodyScrollView.hasVerticalScroller,
            !bodyTextView.isEditable,
            bodyTextView.isSelectable,
            let textContainer = bodyTextView.textContainer,
            let layoutManager = bodyTextView.layoutManager
        else { return false }
        layoutManager.ensureLayout(for: textContainer)
        let viewportHeight = bodyScrollView.contentView.bounds.height
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        return viewportHeight > 0
            && usedHeight > viewportHeight + 1
            && bodyTextView.frame.height + 1 >= usedHeight
    }
    var isGuidanceLayoutValidForE2E: Bool {
        layoutSubtreeIfNeeded()
        let protectedViews = [titleLabel, privacyLabel, actionButton, secondaryActions]
        return sheet.bounds.contains(bodyScrollView.frame)
            && protectedViews.allSatisfy { view in
                view.isHidden || !bodyScrollView.frame.intersects(view.frame)
            }
    }
    var connectionActionKindForE2E: String {
        switch diagnostics.primaryAction {
        case .hidden: "hidden"
        case .retryReceiver: "retryReceiver"
        case .connect: "connect"
        case .repair: "repair"
        case .refreshStatus: "refreshStatus"
        case .review: "review"
        }
    }
    var reviewRecoveryGuidanceVisibleForE2E: Bool {
        switch diagnostics.reviewLaunchState {
        case .idle:
            return bodyTextView.string.contains(L10n.text(
                "Codex 검토 열기",
                "Open Codex review"
            ))
        case .opening:
            return bodyTextView.string.contains(L10n.text(
                "검토용 Terminal과 Codex를 여는 중",
                "Opening the review Terminal and Codex"
            ))
        case .opened:
            return bodyTextView.string.contains("Hooks need review")
                && bodyTextView.string.contains("/hooks")
        case .failed:
            return bodyTextView.string.contains(L10n.text(
                "Codex를 설치·업데이트",
                "Install or update Codex"
            ))
        }
    }
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
                == fullStateGrammarAccessibilityHelp
    }
    var isStateLegendVisible: Bool { !stateLegend.isHidden }
    var isStateLegendAccessible: Bool {
        stateLegend.isAccessibilityElement()
            && stateLegend.accessibilityRole() == .group
            && visibleStateLegendLabels
                .allSatisfy {
                    $0.isAccessibilityElement() && $0.accessibilityRole() == .staticText
                }
    }
    var stateLegendScopeForE2E: String {
        switch stateLegendScope {
        case .essentials: "essentials"
        case .allStates: "allStates"
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
            && additionalStateLegendSignals.allSatisfy { $0.hasNoAnimationsForE2E }
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
        scope: StateLegendScope = .essentials,
        onCompleted: @escaping () -> Void
    ) -> Bool {
        guard !isGuidanceVisible else { return false }
        cancelStateLegend()

        stateLegendReduceMotion = reduceMotion
        stateLegendScope = scope
        stateLegendCompletion = onCompleted
        updateStateLegendScope()
        updateStateLegendSignals(reduceMotion: reduceMotion)
        stateLegend.alphaValue = reduceMotion ? 1 : 0
        stateLegend.isHidden = false
        let accessibilityHelp = stateGrammarAccessibilityHelp(for: scope)
        stateLegend.setAccessibilityHelp(accessibilityHelp)
        NSAccessibility.post(
            element: stateLegend,
            notification: .announcementRequested,
            userInfo: [
                .announcement: accessibilityHelp,
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
        stateLegendHelpButton.setAccessibilityHelp(fullStateGrammarAccessibilityHelp)
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
            connectionProgressIndicator,
            bodyScrollView,
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
        let essentialRows: [NSView] = [
            stateLegendRow(
                signal: activeLegendSignal,
                label: activeLegendLabel,
                accessibilityHelp: L10n.text(
                    "움직임은 최근 에이전트 활동이 관찰됐음을 뜻합니다. 동작 줄이기에서는 꺾쇠로 표시합니다.",
                    "Movement means recent agent activity was observed. Reduce Motion replaces it with a chevron."
                )
            ),
            stateLegendRow(
                signal: attentionLegendSignal,
                label: attentionLegendLabel,
                accessibilityHelp: L10n.text(
                    "고리는 Codex가 사용자 확인이나 승인을 요청했음을 뜻합니다.",
                    "A ring means Codex requested user attention or approval."
                )
            ),
            stateLegendRow(
                signal: turnEndedLegendSignal,
                label: turnEndedLegendLabel,
                accessibilityHelp: L10n.text(
                    "바깥으로 번지는 파동은 최상위 에이전트 턴 종료가 방금 관찰됐음을 뜻하며 성공 판정은 아닙니다.",
                    "An outward ripple means a top-level agent turn end was just observed; it does not claim success."
                )
            ),
        ]
        additionalStateLegendRows = [
            stateLegendRow(
                signal: uncertainLegendSignal,
                label: uncertainLegendLabel,
                accessibilityHelp: L10n.text(
                    "분절 고리는 최근 상태를 더 이상 확정할 수 없음을 뜻합니다.",
                    "A segmented ring means the recent state can no longer be confirmed."
                )
            ),
            stateLegendRow(
                signal: finishedLegendSignal,
                label: finishedLegendLabel,
                accessibilityHelp: L10n.text(
                    "열린 호는 종료가 관찰됐지만 성공, 실패 또는 취소 결과는 제공되지 않았음을 뜻합니다.",
                    "An open arc means an end was observed without a success, failure, or cancellation result."
                )
            ),
            stateLegendRow(
                signal: completedLegendSignal,
                label: completedLegendLabel,
                accessibilityHelp: L10n.text(
                    "이중 후광은 observation source가 성공을 명시했음을 뜻합니다.",
                    "A double halo means the observation source explicitly reported success."
                )
            ),
            stateLegendRow(
                signal: cancelledLegendSignal,
                label: cancelledLegendLabel,
                accessibilityHelp: L10n.text(
                    "가로 막대는 observation source가 취소를 명시했음을 뜻합니다.",
                    "A horizontal bar means the observation source explicitly reported cancellation."
                )
            ),
            stateLegendRow(
                signal: failedLegendSignal,
                label: failedLegendLabel,
                accessibilityHelp: L10n.text(
                    "마름모는 observation source가 실패를 명시했음을 뜻합니다.",
                    "A diamond means the observation source explicitly reported failure."
                )
            ),
        ]
        stateLegendStack.translatesAutoresizingMaskIntoConstraints = false
        stateLegendStack.orientation = .vertical
        stateLegendStack.alignment = .leading
        stateLegendStack.spacing = 2
        (essentialRows + additionalStateLegendRows).forEach {
            stateLegendStack.addArrangedSubview($0)
        }
        stateLegendTitle.translatesAutoresizingMaskIntoConstraints = false
        stateLegend.addSubview(stateLegendTitle)
        stateLegend.addSubview(stateLegendStack)

        let heightConstraint = stateLegend.heightAnchor.constraint(equalToConstant: 108)
        stateLegendHeightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            stateLegend.centerXAnchor.constraint(equalTo: centerXAnchor),
            stateLegend.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            stateLegend.widthAnchor.constraint(equalToConstant: 286),
            heightConstraint,
            stateLegendTitle.leadingAnchor.constraint(equalTo: stateLegend.leadingAnchor, constant: 15),
            stateLegendTitle.topAnchor.constraint(equalTo: stateLegend.topAnchor, constant: 11),
            stateLegendTitle.trailingAnchor.constraint(
                lessThanOrEqualTo: stateLegend.trailingAnchor,
                constant: -15
            ),
            stateLegendStack.leadingAnchor.constraint(equalTo: stateLegendTitle.leadingAnchor),
            stateLegendStack.trailingAnchor.constraint(
                lessThanOrEqualTo: stateLegend.trailingAnchor,
                constant: -15
            ),
            stateLegendStack.topAnchor.constraint(equalTo: stateLegendTitle.bottomAnchor, constant: 5),
            stateLegendStack.bottomAnchor.constraint(
                lessThanOrEqualTo: stateLegend.bottomAnchor,
                constant: -9
            ),
        ])
        updateStateLegendScope()
        updateContrastAppearance()
    }

    private func stateLegendRow(
        signal: StateLegendSignalView,
        label: NSTextField,
        accessibilityHelp: String
    ) -> NSStackView {
        signal.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.setAccessibilityElement(true)
        label.setAccessibilityRole(.staticText)
        label.setAccessibilityLabel(label.stringValue)
        label.setAccessibilityHelp(accessibilityHelp)
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

    private var fullStateGrammarAccessibilityHelp: String {
        L10n.text(
            "움직임은 활동 중이며 동작 줄이기에서는 꺾쇠로 대신합니다. 고리는 확인 필요, 바깥 파동은 방금 관찰된 턴 종료를 뜻합니다. 분절 고리는 불확실, 열린 호는 결과를 알 수 없는 종료, 이중 후광은 명시된 성공, 가로 막대는 명시된 취소, 마름모는 명시된 실패를 뜻합니다.",
            "Movement means active and becomes a chevron with Reduce Motion. A ring means needs attention, and an outward ripple means a newly observed turn end. A segmented ring means uncertain, an open arc means an end with no known result, a double halo means explicitly reported success, a horizontal bar means explicitly cancelled, and a diamond means explicitly failed."
        )
    }

    private func stateGrammarAccessibilityHelp(for scope: StateLegendScope) -> String {
        switch scope {
        case .essentials: stateGrammarAccessibilityHelp
        case .allStates: fullStateGrammarAccessibilityHelp
        }
    }

    private var additionalStateLegendSignals: [StateLegendSignalView] {
        [
            uncertainLegendSignal,
            finishedLegendSignal,
            completedLegendSignal,
            cancelledLegendSignal,
            failedLegendSignal,
        ]
    }

    private var allStateLegendSignals: [StateLegendSignalView] {
        [activeLegendSignal, attentionLegendSignal, turnEndedLegendSignal]
            + additionalStateLegendSignals
    }

    private var additionalStateLegendLabels: [NSTextField] {
        [
            uncertainLegendLabel,
            finishedLegendLabel,
            completedLegendLabel,
            cancelledLegendLabel,
            failedLegendLabel,
        ]
    }

    private var allStateLegendLabels: [NSTextField] {
        [activeLegendLabel, attentionLegendLabel, turnEndedLegendLabel]
            + additionalStateLegendLabels
    }

    private var visibleStateLegendLabels: [NSTextField] {
        switch stateLegendScope {
        case .essentials:
            [activeLegendLabel, attentionLegendLabel, turnEndedLegendLabel]
        case .allStates:
            allStateLegendLabels
        }
    }

    private func updateStateLegendScope() {
        let showsAllStates = stateLegendScope == .allStates
        additionalStateLegendRows.forEach { $0.isHidden = !showsAllStates }
        stateLegendHeightConstraint?.constant = showsAllStates ? 218 : 108
        stateLegend.setAccessibilityHelp(stateGrammarAccessibilityHelp(for: stateLegendScope))
        stateLegend.needsLayout = true
    }

    private func updateStateLegendSignals(reduceMotion: Bool) {
        activeLegendLabel.stringValue = reduceMotion
            ? L10n.text("꺾쇠 · 활동 중", "Chevron · Active")
            : L10n.text("움직임 · 활동 중", "Movement · Active")
        activeLegendLabel.setAccessibilityLabel(activeLegendLabel.stringValue)
        allStateLegendSignals.forEach {
            $0.updatePresentation(
                reduceMotion: reduceMotion,
                increaseContrast: increaseContrast
            )
        }
    }

    private func stopStateLegendAnimations() {
        allStateLegendSignals.forEach {
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
        connectionProgressIndicator.style = .spinning
        connectionProgressIndicator.controlSize = .small
        connectionProgressIndicator.isDisplayedWhenStopped = false
        connectionProgressIndicator.isHidden = true
        bodyScrollView.drawsBackground = false
        bodyScrollView.borderType = .noBorder
        bodyScrollView.hasHorizontalScroller = false
        bodyScrollView.hasVerticalScroller = true
        bodyScrollView.autohidesScrollers = true
        bodyScrollView.scrollerStyle = .overlay
        bodyScrollView.verticalScrollElasticity = .none
        bodyTextView.font = .systemFont(ofSize: 11)
        bodyTextView.isEditable = false
        bodyTextView.isSelectable = true
        bodyTextView.isRichText = false
        bodyTextView.drawsBackground = false
        bodyTextView.textContainerInset = .zero
        bodyTextView.textContainer?.lineFragmentPadding = 0
        bodyTextView.isHorizontallyResizable = false
        bodyTextView.isVerticallyResizable = true
        bodyTextView.autoresizingMask = [.width]
        bodyTextView.minSize = .zero
        bodyTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        bodyTextView.textContainer?.widthTracksTextView = true
        bodyTextView.textContainer?.containerSize = NSSize(
            width: bodyScrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        bodyScrollView.documentView = bodyTextView
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
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: connectionProgressIndicator.leadingAnchor,
                constant: -8
            ),
            connectionProgressIndicator.centerYAnchor.constraint(
                equalTo: titleLabel.centerYAnchor
            ),
            connectionProgressIndicator.trailingAnchor.constraint(
                equalTo: closeButton.leadingAnchor,
                constant: -8
            ),
            connectionProgressIndicator.widthAnchor.constraint(equalToConstant: 14),
            connectionProgressIndicator.heightAnchor.constraint(equalToConstant: 14),
            closeButton.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            bodyScrollView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyScrollView.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -18),
            bodyScrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            bodyScrollView.bottomAnchor.constraint(equalTo: actionButton.topAnchor, constant: -10),
            privacyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            privacyLabel.trailingAnchor.constraint(equalTo: bodyScrollView.trailingAnchor),
            privacyLabel.bottomAnchor.constraint(equalTo: sheet.bottomAnchor, constant: -14),
            actionButton.trailingAnchor.constraint(equalTo: bodyScrollView.trailingAnchor),
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
            setBodyText(L10n.text(
                "Codex 이벤트를 받을 수 없습니다.\n\n\(error)",
                "agent-meong cannot receive Codex events.\n\n\(error)"
            ))
        } else if diagnostics.rejectedEventCount > 0 {
            titleLabel.stringValue = L10n.text(
                "Codex 이벤트 형식이 맞지 않아요",
                "The Codex event format does not match"
            )
            setBodyText(L10n.text(
                "장면은 변경하지 않았습니다.\nadapter와 앱 버전을 확인하세요.\n\n거절된 이벤트 · \(diagnostics.rejectedEventCount)개",
                "The scene was left unchanged.\nCheck the adapter and app versions.\n\nRejected events · \(diagnostics.rejectedEventCount)"
            ))
        } else if !diagnostics.receiverReady {
            titleLabel.stringValue = L10n.text(
                "로컬 수신기를 준비하고 있어요",
                "Preparing the local receiver"
            )
            setBodyText(L10n.text(
                "Codex 이벤트를 받을 준비가 끝날 때까지 잠시 기다려 주세요.",
                "Please wait while agent-meong gets ready to receive Codex events."
            ))
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
            "관찰: 작업·도구 범주·승인 요청·서브에이전트·종료\n저장·로그·전송 안 함: 프롬프트·응답·명령·파일 경로·tool input/output",
            "Observes: work, tool category, approval requests, subagents, finish\nNever stores, logs, or sends: prompts, responses, commands, paths, tool input/output"
        )
        updateConnectionProgressIndicator()
    }

    private func updateConnectionProgressIndicator() {
        let isChecking = diagnostics.receiverError == nil
            && diagnostics.rejectedEventCount == 0
            && (!diagnostics.receiverReady
                || diagnostics.hookInstallationState == .checking)
        connectionProgressIndicator.isHidden = !isChecking
        connectionProgressAnimating = isChecking
        if isChecking {
            connectionProgressIndicator.startAnimation(nil)
        } else {
            connectionProgressIndicator.stopAnimation(nil)
        }
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
        bodyTextView.textColor = .white.withAlphaComponent(increaseContrast ? 0.96 : 0.74)
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
        allStateLegendLabels.forEach {
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
        setBodyText(result)
    }

    private func setBodyText(_ text: String) {
        guard bodyTextView.string != text else { return }
        bodyTextView.string = text
        bodyTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
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
                    "● 앱 준비됨\n○ Codex 설치와 연결 상태 확인 중\n\n설치 환경에 따라 최대 수십 초 걸릴 수 있어요.",
                    "● App ready\n○ Checking Codex and its connection\n\nThis can take tens of seconds on some installations."
                )
            )
        case .notInstalled:
            titleLabel.stringValue = L10n.text("Codex 연결", "Connect Codex")
            setInstallationBody(
                L10n.text(
                    "Codex App · ChatGPT 안의 Codex · Codex CLI\n\n‘연결 시작’을 누르면 개인 Codex 설정에 agent-meong\n연결 항목만 추가합니다. 기존 설정은 그대로 둡니다.\n\n앱이 검토용 Terminal과 Codex를 자동으로 엽니다.\n직접 할 일은 Codex의 보안 확인 한 번뿐입니다.",
                    "Codex App · Codex in ChatGPT · Codex CLI\n\nConnect adds only agent-meong entries to your personal\nCodex settings and leaves existing settings unchanged.\n\nThe app opens a review Terminal and Codex automatically.\nYour only manual step is Codex's security confirmation."
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
                    "● Codex 연결 항목 7개 준비됨\n● Codex에서 활성화·신뢰 확인됨\n○ 첫 agent 활동 대기 중\n\n‘Codex · 활동 대기’면 연결은 끝났습니다. 검토용\nTerminal은 닫아도 됩니다. 바로 시험하려면 닫기 전에\n간단한 요청을 보내 보세요(선택). 이전에 열어 둔\nCodex는 완전히 종료하고 다시 여세요.",
                    "● All 7 Codex connection entries are ready\n● Enabled and trusted in Codex\n○ Waiting for the first agent activity\n\n‘Codex · waiting for activity’ means setup is complete.\nYou may close the review Terminal. To test now, send a\nsimple request before closing it (optional). Fully quit and\nreopen any Codex instance that was already open."
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
                    "● lifecycle command hook 설치됨\n○ 활성·신뢰 상태를 이번에는 읽지 못함\n\n",
                    "● Lifecycle command hooks installed\n○ Enabled and trusted state could not be read this time\n\n"
                ) + reviewInstructions
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
                "‘Codex 검토 열기’를 누르면 앱이 검토용 Terminal과 Codex를 엽니다.",
                "Open Codex review opens a review Terminal and Codex for you."
            )
        case .opening:
            L10n.text(
                "검토용 Terminal과 Codex를 여는 중입니다.",
                "Opening the review Terminal and Codex."
            )
        case .opened:
            L10n.text(
                "검토용 Codex를 열었습니다. 보통 ‘Hooks need review’가\n바로 보이므로 붙여넣기나 Return은 필요 없습니다.\n‘Review hooks’를 선택하세요. 일반 입력 화면만 보이면\n/hooks를 입력하고 Return을 누르세요.",
                "The review Codex is open. ‘Hooks need review’ normally\nappears automatically, so no paste or Return is needed.\nChoose Review hooks. Only if you see a regular prompt,\ntype /hooks and press Return."
            )
        case .failed:
            L10n.text(
                "Codex 실행 파일을 찾지 못했거나 Terminal을 열지 못했습니다.\nCodex를 설치·업데이트한 뒤 다시 시도하세요. 직접 CLI를\n열었다면 /hooks를 입력하고 Return을 누르세요.",
                "Codex could not be found or Terminal could not be opened.\nInstall or update Codex, then try again. If you opened the\nCLI yourself, type /hooks and press Return."
            )
        }
        let trustInstruction: String
        if diagnostics.otherPendingHookCount == 0 {
            trustInstruction = L10n.text(
                "현재 다른 검토 대기 hook은 없습니다. 이 화면에서는\n‘Trust all’ 옵션을 사용해도 됩니다.",
                "No other hooks are waiting for review. It is safe to use\nthe Trust all option on this screen."
            )
        } else if let count = diagnostics.otherPendingHookCount {
            trustInstruction = L10n.text(
                "다른 검토 대기 hook이 \(count)개 있습니다. agent-meong\n7개만 개별 신뢰하고 ‘Trust all’은 사용하지 마세요.",
                "There are \(count) other hooks waiting for review. Trust only\nthe 7 agent-meong entries; do not use Trust all."
            )
        } else {
            trustInstruction = L10n.text(
                "다른 검토 대기 항목이 있는지 확인하세요. 이 7개만\n대기 중인 경우에만 ‘Trust all’을 사용하세요.",
                "Check whether anything else is waiting for review. Use\nTrust all only when these are the only 7 pending entries."
            )
        }
        return firstStep + L10n.text(
            "\n\nUser config에서 아래 lifecycle event와 command 정의를\n확인하세요. 다른 항목은 바꾸지 마세요.\nUserPromptSubmit · PreToolUse · PermissionRequest\nPostToolUse · Stop · SubagentStart · SubagentStop\n각 command가 같은 agent-meong forwarder를 가리키는지\n확인한 뒤 7개를 활성화·신뢰하세요.\n",
            "\n\nUnder User config, review these lifecycle events and their\ncommand definitions. Leave everything else unchanged.\nUserPromptSubmit · PreToolUse · PermissionRequest\nPostToolUse · Stop · SubagentStart · SubagentStop\nConfirm all commands point to the same agent-meong forwarder,\nthen enable and trust all 7.\n"
        ) + trustInstruction + L10n.text(
            "\n승인 상태는 앱이 자동으로 다시 확인합니다.",
            "\nagent-meong rechecks approval automatically."
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
            "agent-meong 기본 hook과 이 연결의 오브젝트·종료 흔적·확인 기록을 지웁니다. 다른 hook과 별도 CODEX_HOME은 유지합니다.\n\n완료 후 열려 있던 Codex App과 CLI를 완전히 종료하고 다시 연 뒤, /hooks의 다른 사용자 hook도 다시 검토하세요.",
            "This removes the default agent-meong hook and this connection's objects, end receipts, and confirmation. Other hooks and custom CODEX_HOME connections remain.\n\nAfterward, fully quit and reopen running Codex App and CLI instances, then review other user hooks in /hooks again."
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
