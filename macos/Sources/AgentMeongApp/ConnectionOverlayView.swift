import AppKit

struct ConnectionDiagnostics {
    let receiverReady: Bool
    let lastEventAt: Date?
    let previouslyConfirmedAt: Date?
    let rejectedEventCount: Int
    let receiverError: String?
    let hookInstallationState: CodexHookInstallationState
    let inlineHooksPresent: Bool
    let managedHookPresent: Bool
    let hookProblemOverridesHistory: Bool
    let observedConnectionIsCurrentHook: Bool
}

@MainActor
final class ConnectionOverlayView: NSView {
    var onRetry: (() -> Void)?
    var onInstall: (() -> Void)?
    var onRefreshHookStatus: (() -> Void)?
    var onUninstall: (() -> Void)?
    var onForget: (() -> Void)?

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
        hookProblemOverridesHistory: false,
        observedConnectionIsCurrentHook: false
    )

    var isGuidanceVisible: Bool { !sheet.isHidden }
    var hooksCommandCopiedForE2E: Bool {
        hooksPasteboard.string(forType: .string) == "/hooks"
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureChip()
        configureSheet()
        update(diagnostics, now: .now)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ next: ConnectionDiagnostics, now: Date) {
        let receivedFirstEvent = diagnostics.lastEventAt == nil && next.lastEventAt != nil
        let recovered = diagnostics.rejectedEventCount > 0
            && next.rejectedEventCount == 0
            && next.lastEventAt != nil
        let hasConfirmedConnection = next.lastEventAt != nil
            || (next.previouslyConfirmedAt != nil && !next.hookProblemOverridesHistory)
        let requiresHookGuidance = requiresHookGuidance(next.hookInstallationState)
            && (!hasConfirmedConnection
                || (next.managedHookPresent && !next.observedConnectionIsCurrentHook))
        diagnostics = next
        if !hasResolvedInitialVisibility, next.hookInstallationState != .checking {
            hasResolvedInitialVisibility = true
            let needsGuidance = next.receiverError != nil
                || next.rejectedEventCount > 0
                || (next.hookInstallationState != .installed && !hasConfirmedConnection)
                || next.inlineHooksPresent
                || !hasConfirmedConnection
            sheet.isHidden = !needsGuidance
        }
        if (receivedFirstEvent || recovered), !requiresHookGuidance {
            sheet.isHidden = true
        }
        if next.receiverError != nil
            || next.rejectedEventCount > 0
            || requiresHookGuidance
        {
            sheet.isHidden = false
        }
        updateChip(now: now)
        updateSheet()
    }

    func setIncreaseContrast(_ isEnabled: Bool) {
        guard increaseContrast != isEnabled else { return }
        increaseContrast = isEnabled
        updateContrastAppearance()
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
        addSubview(chip)
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            chip.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            chip.heightAnchor.constraint(equalToConstant: 25),
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
        let accessibilityValue: String
        if diagnostics.receiverError != nil {
            chip.title = L10n.text(
                "  !  Codex · 수신기 오류  ",
                "  !  Codex · receiver error  "
            )
            accessibilityValue = L10n.text("수신기 오류", "Receiver error")
        } else if diagnostics.rejectedEventCount > 0 {
            chip.title = L10n.text(
                "  !  Codex · 형식 확인  ",
                "  !  Codex · check format  "
            )
            accessibilityValue = L10n.text(
                "이벤트 형식 확인 필요",
                "Event format needs attention"
            )
        } else if currentHookProblemShouldLead,
            let status = hookProblemChip(for: diagnostics.hookInstallationState)
        {
            chip.title = status.title
            accessibilityValue = status.accessibilityValue
        } else if hasConfirmedConnection, diagnostics.inlineHooksPresent {
            chip.title = L10n.text(
                "  ●  Codex · source 확인  ",
                "  ●  Codex · check sources  "
            )
            accessibilityValue = L10n.text(
                "연결됨, Codex hook source 병합 확인 필요",
                "Connected; review merged Codex hook sources"
            )
        } else if let lastEventAt = diagnostics.lastEventAt {
            let age = L10n.relativeAge(from: lastEventAt, to: now)
            chip.title = "  ●  Codex · \(age)  "
            accessibilityValue = L10n.text(
                "연결됨, 마지막 이벤트 \(age)",
                "Connected; last event \(age)"
            )
        } else if diagnostics.previouslyConfirmedAt != nil,
            !diagnostics.hookProblemOverridesHistory
        {
            chip.title = L10n.text(
                "  ○  Codex · 이벤트 대기  ",
                "  ○  Codex · waiting for event  "
            )
            accessibilityValue = L10n.text(
                "연결됨, 이벤트 대기 중",
                "Connected; waiting for an event"
            )
        } else if let status = hookProblemChip(for: diagnostics.hookInstallationState) {
            chip.title = status.title
            accessibilityValue = status.accessibilityValue
        } else if diagnostics.inlineHooksPresent {
            chip.title = L10n.text(
                "  !  Codex · source 확인  ",
                "  !  Codex · check sources  "
            )
            accessibilityValue = L10n.text(
                "Codex hook source 병합 확인 필요",
                "Review merged Codex hook sources"
            )
        } else {
            chip.title = L10n.text(
                "  ○  Codex · 확인 필요  ",
                "  ○  Codex · check connection  "
            )
            accessibilityValue = L10n.text(
                "연결 확인 필요",
                "Connection needs attention"
            )
        }
        chip.setAccessibilityValue(accessibilityValue)
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
        } else if currentHookProblemShouldLead {
            updateInstallationSheet()
        } else if let date = diagnostics.lastEventAt {
            titleLabel.stringValue = L10n.text(
                "OpenAI Codex 연결됨",
                "OpenAI Codex connected"
            )
            setInstallationBody(
                L10n.text(
                    "● 로컬 수신기 준비됨\n● 이벤트 수신 확인됨\n마지막 이벤트 · \(L10n.time(date))\(secondaryHookStatusNote)",
                    "● Local receiver ready\n● Event receipt confirmed\nLast event · \(L10n.time(date))\(secondaryHookStatusNote)"
                )
            )
        } else if let date = diagnostics.previouslyConfirmedAt,
            !diagnostics.hookProblemOverridesHistory
        {
            titleLabel.stringValue = L10n.text(
                "OpenAI Codex 연결됨",
                "OpenAI Codex connected"
            )
            setInstallationBody(
                L10n.text(
                    "● 이전 실제 이벤트 확인됨\n○ 이번 실행 이벤트 대기 중\n마지막 확인 · \(L10n.time(date))\(secondaryHookStatusNote)",
                    "● Earlier real event confirmed\n○ Waiting for an event in this run\nLast confirmed · \(L10n.time(date))\(secondaryHookStatusNote)"
                )
            )
        } else if requiresHookGuidance(diagnostics.hookInstallationState) {
            updateInstallationSheet()
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
    }

    private func setInstallationBody(_ body: String) {
        var result = body
        if
            currentHookProblemShouldLead,
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

    private func hookProblemChip(
        for state: CodexHookInstallationState
    ) -> (title: String, accessibilityValue: String)? {
        switch state {
        case .notInstalled:
            (
                L10n.text("  ○  Codex · 연결 필요  ", "  ○  Codex · connect  "),
                L10n.text("연결 필요", "Connection required")
            )
        case .hooksDisabled:
            (
                L10n.text("  !  Codex · hooks 꺼짐  ", "  !  Codex · hooks off  "),
                L10n.text("Codex hooks 비활성화", "Codex hooks are disabled")
            )
        case .managedHooksOnly:
            (
                L10n.text("  !  Codex · 정책 제한  ", "  !  Codex · policy blocked  "),
                L10n.text("관리형 hooks 정책 제한", "Managed-hooks-only policy")
            )
        case .newerVersion:
            (
                L10n.text("  !  Codex · 앱 업데이트  ", "  !  Codex · update app  "),
                L10n.text("agent-meong 앱 업데이트 필요", "Update agent-meong")
            )
        case .invalidConfiguration:
            (
                L10n.text("  !  Codex · 설정 확인  ", "  !  Codex · check config  "),
                L10n.text("Codex hook 설정 확인 필요", "Check the Codex hook configuration")
            )
        case .needsRepair:
            (
                L10n.text("  !  Codex · 복구 필요  ", "  !  Codex · repair  "),
                L10n.text("Codex 연결 복구 필요", "Repair the Codex connection")
            )
        case .unavailable:
            (
                L10n.text("  !  Codex · 상태 오류  ", "  !  Codex · status error  "),
                L10n.text("Codex 연결 상태 오류", "Codex connection status error")
            )
        case .checking, .installed:
            nil
        }
    }

    private func requiresHookGuidance(_ state: CodexHookInstallationState) -> Bool {
        switch state {
        case .checking, .installed:
            false
        case .notInstalled, .needsRepair, .invalidConfiguration,
            .hooksDisabled, .managedHooksOnly, .newerVersion, .unavailable:
            true
        }
    }

    private func isConfigurationBlocked(_ state: CodexHookInstallationState) -> Bool {
        switch state {
        case .invalidConfiguration, .hooksDisabled, .managedHooksOnly:
            true
        case .checking, .notInstalled, .installed, .needsRepair, .newerVersion, .unavailable:
            false
        }
    }

    private var hasConfirmedConnection: Bool {
        diagnostics.lastEventAt != nil
            || (diagnostics.previouslyConfirmedAt != nil
                && !diagnostics.hookProblemOverridesHistory)
    }

    private var hasObservedHistory: Bool {
        diagnostics.lastEventAt != nil || diagnostics.previouslyConfirmedAt != nil
    }

    private var currentHookProblemShouldLead: Bool {
        requiresHookGuidance(diagnostics.hookInstallationState)
            && (diagnostics.hookProblemOverridesHistory
                || (diagnostics.managedHookPresent
                    && !diagnostics.observedConnectionIsCurrentHook))
    }

    private var secondaryHookStatusNote: String {
        if diagnostics.observedConnectionIsCurrentHook {
            return L10n.text(
                "\n참고: 현재 hook을 제거하면 장면과 재시작 체크포인트도 비웁니다.",
                "\nNote: removing the current hook also clears the scene and restart checkpoint."
            )
        }
        return L10n.text(
            "\n참고: custom 연결 기록은 현재 기본 hook과 별도이며, 기록 지우기는 장면과 체크포인트를 비웁니다.",
            "\nNote: custom history is separate from the default hook; forgetting it clears the scene and checkpoint."
        )
    }

    @objc private func toggleSheet() {
        sheet.isHidden.toggle()
    }

    @objc private func closeSheet() {
        sheet.isHidden = true
    }

    private func updateActionButtons() {
        let canRemoveCurrentHook = diagnostics.managedHookPresent
            && diagnostics.hookInstallationState != .checking
            && diagnostics.hookInstallationState != .newerVersion
        removeHookButton.isHidden = !canRemoveCurrentHook
        let removesObservedConnection = diagnostics.observedConnectionIsCurrentHook
            || !hasObservedHistory
        removeHookButton.title = removesObservedConnection
            ? L10n.text("연결 해제", "Disconnect")
            : L10n.text("기본 hook 제거", "Remove default hook")
        removeHookButton.setAccessibilityLabel(
            removesObservedConnection
                ? L10n.text("현재 Codex 연결 해제", "Disconnect the current Codex connection")
                : L10n.text("기본 Codex hook 제거", "Remove the default Codex hook")
        )
        removeHookButton.setAccessibilityHelp(
            diagnostics.observedConnectionIsCurrentHook
                ? L10n.text(
                    "현재 hook과 함께 장면 및 재시작 체크포인트를 비웁니다.",
                    "Removes the current hook and clears the scene and restart checkpoint."
                )
                : L10n.text(
                    "현재 기본 hook만 제거하고 별도 custom 관찰 기록과 장면은 유지합니다.",
                    "Removes only the current default hook and keeps separate custom history and the scene."
                )
        )

        let canForgetSeparateConnection = hasObservedHistory
            && !diagnostics.observedConnectionIsCurrentHook
        forgetButton.isHidden = !canForgetSeparateConnection
        forgetButton.title = diagnostics.hookProblemOverridesHistory
            ? L10n.text("별도 기록 지우기", "Forget saved history")
            : diagnostics.managedHookPresent
                ? L10n.text("custom 기록 지우기", "Forget custom history")
                : L10n.text("연결 기록 지우기", "Forget history")
        forgetButton.setAccessibilityLabel(
            diagnostics.hookProblemOverridesHistory
                ? L10n.text("별도 Codex 관찰 기록 지우기", "Forget saved Codex history")
                : diagnostics.managedHookPresent
                ? L10n.text("custom Codex 연결 기록 지우기", "Forget custom Codex history")
                : L10n.text("Codex 연결 기록 지우기", "Forget Codex connection history")
        )
        forgetButton.setAccessibilityHelp(
            L10n.text(
                "hook은 제거하지 않고 연결 기록, 현재 장면, 재시작 체크포인트를 비웁니다.",
                "Keeps hooks installed but clears connection history, the scene, and the restart checkpoint."
            )
        )
        if diagnostics.receiverError != nil {
            actionButton.title = L10n.text("다시 시도", "Try again")
            actionButton.isHidden = false
            return
        }
        if diagnostics.rejectedEventCount > 0 {
            actionButton.title = L10n.text("Codex 연결 복구", "Repair Codex connection")
            actionButton.isHidden = false
            return
        }
        if currentHookProblemShouldLead {
            switch diagnostics.hookInstallationState {
            case .needsRepair:
                actionButton.title = L10n.text(
                    "현재 hook 복구",
                    "Repair current hook"
                )
                actionButton.isHidden = false
            case .invalidConfiguration, .hooksDisabled, .managedHooksOnly, .unavailable:
                actionButton.title = L10n.text("다시 확인", "Check again")
                actionButton.isHidden = false
            case .newerVersion:
                actionButton.isHidden = true
            case .checking, .notInstalled, .installed:
                break
            }
            return
        }
        if hasConfirmedConnection {
            actionButton.title = L10n.text("/hooks 복사", "Copy /hooks")
            actionButton.isHidden = false
            return
        }
        if diagnostics.hookInstallationState == .newerVersion {
            actionButton.isHidden = true
            return
        }
        if isConfigurationBlocked(diagnostics.hookInstallationState) {
            actionButton.title = L10n.text("다시 확인", "Check again")
            actionButton.isHidden = false
            return
        }
        switch diagnostics.hookInstallationState {
        case .checking:
            actionButton.isHidden = true
        case .notInstalled:
            actionButton.title = L10n.text("Codex 연결하기", "Connect Codex")
            actionButton.isHidden = false
        case .installed:
            actionButton.title = L10n.text("/hooks 복사", "Copy /hooks")
            actionButton.isHidden = false
        case .needsRepair:
            actionButton.title = L10n.text("Codex 연결 복구", "Repair Codex connection")
            actionButton.isHidden = false
        case .invalidConfiguration, .hooksDisabled, .managedHooksOnly:
            actionButton.title = L10n.text("다시 확인", "Check again")
            actionButton.isHidden = false
        case .newerVersion:
            actionButton.isHidden = true
        case .unavailable:
            actionButton.title = L10n.text("다시 확인", "Check again")
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
            titleLabel.stringValue = L10n.text("연결할 에이전트", "Connect an agent")
            setInstallationBody(
                L10n.text(
                    "OpenAI Codex\nCodex App · Codex CLI\n\n버튼을 누르면 현재 사용자 Codex home에\nadapter와 lifecycle hook을 설치합니다.\n기본 경로는 ~/.codex이며 기존 설정은 보존합니다.",
                    "OpenAI Codex\nCodex App · Codex CLI\n\nInstalls an adapter and lifecycle hooks in the\ncurrent user's Codex home. Default: ~/.codex.\nExisting settings are preserved."
                )
            )
        case .installed:
            if let date = diagnostics.previouslyConfirmedAt {
                titleLabel.stringValue = L10n.text(
                    "OpenAI Codex 연결됨",
                    "OpenAI Codex connected"
                )
                setInstallationBody(
                    L10n.text(
                        "● 사용자 hook 설치됨\n● 이전 실제 이벤트 확인됨\n○ 이번 실행 이벤트 대기 중\n\n마지막 확인 · \(L10n.time(date))\n같은 Codex home을 쓰는 App과 CLI에 적용됩니다.",
                        "● User hooks installed\n● Earlier real event confirmed\n○ Waiting for an event in this run\n\nLast confirmed · \(L10n.time(date))\nApplies to App and CLI using the same Codex home."
                    )
                )
            } else {
                titleLabel.stringValue = L10n.text(
                    "마지막 보안 확인",
                    "One final security check"
                )
                setInstallationBody(
                    L10n.text(
                        "● 사용자 hook 설치됨 · Codex CLI에서 /hooks 열기\n○ User config의 agent-meong handler 7개 검토\n\nUserPromptSubmit · Pre/PostToolUse · PermissionRequest\nSubagentStart/Stop · Stop\n/usr/bin/python3 …/AgentMeong/codex-hooks/<opaque>/\ncodex_hook.py\ntype: command · async 아님 · timeout: 2s\nstatus: agent-meong activity [dev.ailab.agent-meong/v3]\n기존의 다른 hook은 함께 보일 수 있으며 별도로 검토합니다.\n\n모두 맞을 때만 신뢰하고 새 local Codex message로 확인하세요.",
                        "● User hooks installed · open /hooks in Codex CLI\n○ Review 7 agent-meong handlers under User config\n\nUserPromptSubmit · Pre/PostToolUse · PermissionRequest\nSubagentStart/Stop · Stop\n/usr/bin/python3 …/AgentMeong/codex-hooks/<opaque>/\ncodex_hook.py\ntype: command · not async · timeout: 2s\nstatus: agent-meong activity [dev.ailab.agent-meong/v3]\nOther existing hooks may coexist; review them separately.\n\nTrust only if all match, then send a new local Codex message."
                    )
                )
            }
        case .needsRepair:
            titleLabel.stringValue = L10n.text(
                "Codex 연결 복구가 필요해요",
                "The Codex connection needs repair"
            )
            setInstallationBody(
                L10n.text(
                    "● 로컬 수신기 준비됨\n○ 사용자 hook 또는 adapter 갱신 필요\n\n기존 Codex 설정은 보존됩니다.\n아래 버튼으로 agent-meong 항목만 복구하세요.",
                    "● Local receiver ready\n○ User hooks or adapter need an update\n\nExisting Codex settings are preserved.\nUse the button below to repair only agent-meong entries."
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

    @objc private func performAction() {
        if diagnostics.receiverError != nil {
            onRetry?()
        } else if diagnostics.rejectedEventCount > 0 {
            onInstall?()
        } else if currentHookProblemShouldLead {
            switch diagnostics.hookInstallationState {
            case .needsRepair:
                onInstall?()
            case .invalidConfiguration, .hooksDisabled, .managedHooksOnly, .unavailable:
                onRefreshHookStatus?()
            case .newerVersion, .checking, .notInstalled, .installed:
                break
            }
        } else if hasConfirmedConnection {
            copyHooksCommand()
        } else if isConfigurationBlocked(diagnostics.hookInstallationState) {
            onRefreshHookStatus?()
        } else {
            switch diagnostics.hookInstallationState {
            case .installed:
                copyHooksCommand()
            case .invalidConfiguration, .hooksDisabled, .managedHooksOnly:
                onRefreshHookStatus?()
            case .newerVersion:
                break
            case .unavailable:
                onRefreshHookStatus?()
            case .checking, .notInstalled, .needsRepair:
                onInstall?()
            }
        }
    }

    @objc private func removeCurrentHook() {
        onUninstall?()
    }

    @objc private func forgetConnection() {
        onForget?()
    }

    private func copyHooksCommand() {
        let pasteboard = hooksPasteboard
        pasteboard.clearContents()
        pasteboard.setString("/hooks", forType: .string)
        actionButton.title = L10n.text("/hooks 복사됨", "/hooks copied")
        actionButton.setAccessibilityLabel(actionButton.title)
        NSAccessibility.post(element: actionButton, notification: .valueChanged)
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

    func showGuidance() {
        sheet.isHidden = false
    }

    private var hooksPasteboard: NSPasteboard {
        guard ProcessInfo.processInfo.environment["AGENT_MEONG_E2E_REPORT"] != nil else {
            return .general
        }
        return NSPasteboard(name: .init("dev.ailab.agent-meong.e2e"))
    }
}
