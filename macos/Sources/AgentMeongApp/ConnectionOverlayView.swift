import AppKit

struct ConnectionDiagnostics {
    let receiverReady: Bool
    let lastEventAt: Date?
    let previouslyConfirmedAt: Date?
    let rejectedEventCount: Int
    let receiverError: String?
    let hookInstallationState: CodexHookInstallationState
    let codexAppAvailable: Bool
}

@MainActor
final class ConnectionOverlayView: NSView {
    var onRetry: (() -> Void)?
    var onInstall: (() -> Void)?
    var onUninstall: (() -> Void)?
    var onOpenCodex: (() -> Void)?

    private let chip = NSButton()
    private let sheet = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Codex")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let privacyLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "다시 시도", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "연결 해제", target: nil, action: nil)
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private var hasResolvedInitialVisibility = false
    private var diagnostics = ConnectionDiagnostics(
        receiverReady: false,
        lastEventAt: nil,
        previouslyConfirmedAt: nil,
        rejectedEventCount: 0,
        receiverError: nil,
        hookInstallationState: .checking,
        codexAppAvailable: false
    )

    var isGuidanceVisible: Bool { !sheet.isHidden }

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
        diagnostics = next
        if !hasResolvedInitialVisibility, next.hookInstallationState != .checking {
            hasResolvedInitialVisibility = true
            let needsGuidance = next.receiverError != nil
                || next.rejectedEventCount > 0
                || next.hookInstallationState != .installed
                || next.previouslyConfirmedAt == nil
            sheet.isHidden = !needsGuidance
        }
        if receivedFirstEvent || recovered {
            sheet.isHidden = true
        }
        if next.receiverError != nil || next.rejectedEventCount > 0 {
            sheet.isHidden = false
        }
        updateChip(now: now)
        updateSheet()
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
        chip.setAccessibilityLabel("Codex 연결 상태")
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

        [titleLabel, bodyLabel, privacyLabel, actionButton, disconnectButton, closeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            sheet.addSubview($0)
        }
        configureSheetContent()
        NSLayoutConstraint.activate(sheetConstraints())
    }

    private func configureSheetContent() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white.withAlphaComponent(0.88)
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.textColor = .white.withAlphaComponent(0.74)
        bodyLabel.maximumNumberOfLines = 10
        privacyLabel.font = .systemFont(ofSize: 10.5)
        privacyLabel.textColor = .white.withAlphaComponent(0.60)
        privacyLabel.maximumNumberOfLines = 3
        actionButton.bezelStyle = .roundRect
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(performAction)
        actionButton.setAccessibilityLabel("Codex 연결 작업")
        disconnectButton.isBordered = false
        disconnectButton.controlSize = .small
        disconnectButton.contentTintColor = .white.withAlphaComponent(0.55)
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnect)
        disconnectButton.setAccessibilityLabel("Codex 연결 해제")
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 16, weight: .light)
        closeButton.contentTintColor = .white.withAlphaComponent(0.45)
        closeButton.target = self
        closeButton.action = #selector(closeSheet)
        closeButton.setAccessibilityLabel("연결 안내 닫기")
    }

    private func sheetConstraints() -> [NSLayoutConstraint] {
        [
            sheet.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            sheet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            sheet.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            sheet.heightAnchor.constraint(equalToConstant: 244),
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
            disconnectButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            disconnectButton.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
        ]
    }

    private func updateChip(now: Date) {
        if diagnostics.receiverError != nil {
            chip.title = "  !  Codex · 수신기 오류  "
            return
        }
        if diagnostics.rejectedEventCount > 0 {
            chip.title = "  !  Codex · 형식 확인  "
            return
        }
        if diagnostics.hookInstallationState == .notInstalled {
            chip.title = "  ○  Codex · 연결 필요  "
            return
        }
        guard let lastEventAt = diagnostics.lastEventAt else {
            chip.title = diagnostics.previouslyConfirmedAt == nil
                ? "  ○  Codex · 확인 필요  "
                : "  ○  Codex · 이벤트 대기  "
            return
        }
        chip.title = "  ●  Codex · \(relativeAge(from: lastEventAt, to: now))  "
    }

    private func updateSheet() {
        updateActionButtons()
        if let error = diagnostics.receiverError {
            titleLabel.stringValue = "로컬 수신기를 열지 못했어요"
            bodyLabel.stringValue = "Codex 이벤트를 받을 수 없습니다.\n\n\(error)"
        } else if diagnostics.rejectedEventCount > 0 {
            titleLabel.stringValue = "Codex 이벤트 형식이 맞지 않아요"
            bodyLabel.stringValue = "장면은 변경하지 않았습니다.\nadapter와 앱 버전을 확인하세요.\n\n거절된 이벤트 · \(diagnostics.rejectedEventCount)개"
        } else if !diagnostics.receiverReady {
            titleLabel.stringValue = "로컬 수신기를 준비하고 있어요"
            bodyLabel.stringValue = "Codex 이벤트를 받을 준비가 끝날 때까지 잠시 기다려 주세요."
        } else if let date = diagnostics.lastEventAt {
            titleLabel.stringValue = "OpenAI Codex 연결됨"
            bodyLabel.stringValue = "● 로컬 수신기 준비됨\n● 이벤트 수신 확인됨\n마지막 이벤트 · \(exactTime(date))"
        } else {
            updateInstallationSheet()
        }
        privacyLabel.stringValue = "관찰: 작업·도구 범주·승인·서브에이전트·종료\n수집 안 함: 프롬프트·응답·명령·파일 경로·tool input/output"
    }

    private func relativeAge(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 { return "방금" }
        if seconds < 60 { return "\(seconds)초 전" }
        if seconds < 3_600 { return "\(seconds / 60)분 전" }
        return "\(seconds / 3_600)시간 전"
    }

    private func exactTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    @objc private func toggleSheet() {
        sheet.isHidden.toggle()
    }

    @objc private func closeSheet() {
        sheet.isHidden = true
    }

    private func updateActionButtons() {
        disconnectButton.isHidden = true
        if diagnostics.receiverError != nil {
            actionButton.title = "다시 시도"
            actionButton.isHidden = false
            return
        }
        if diagnostics.rejectedEventCount > 0 {
            actionButton.title = "Codex 연결 복구"
            actionButton.isHidden = false
            disconnectButton.isHidden = diagnostics.hookInstallationState != .installed
            return
        }
        switch diagnostics.hookInstallationState {
        case .checking:
            actionButton.isHidden = true
        case .notInstalled:
            actionButton.title = "Codex 연결하기"
            actionButton.isHidden = false
        case .installed:
            actionButton.title = "Codex App 열기"
            actionButton.isHidden = !diagnostics.codexAppAvailable
            disconnectButton.isHidden = false
        case .needsRepair:
            actionButton.title = "Codex 연결 복구"
            actionButton.isHidden = false
            disconnectButton.isHidden = false
        case .invalidConfiguration:
            actionButton.isHidden = true
        case .unavailable:
            actionButton.title = "다시 시도"
            actionButton.isHidden = false
        }
    }

    private func updateInstallationSheet() {
        switch diagnostics.hookInstallationState {
        case .checking:
            titleLabel.stringValue = "Codex 연결을 확인하고 있어요"
            bodyLabel.stringValue = "● 로컬 수신기 준비됨\n○ 사용자 연결 확인 중"
        case .notInstalled:
            titleLabel.stringValue = "연결할 에이전트"
            bodyLabel.stringValue = "OpenAI Codex\nCodex App · Codex CLI\n\n한 번 연결하면 두 환경에 함께 적용됩니다.\n버튼을 누르면 agent-meong이 adapter와 사용자 hook을\n설치하고 기존 Codex 설정은 그대로 보존합니다."
        case .installed:
            if let date = diagnostics.previouslyConfirmedAt {
                titleLabel.stringValue = "OpenAI Codex 연결됨"
                bodyLabel.stringValue = "● 사용자 hook 설치됨\n● 이전 실제 이벤트 확인됨\n○ 이번 실행 이벤트 대기 중\n\n마지막 확인 · \(exactTime(date))\nCodex App과 CLI에 함께 적용됩니다."
            } else {
                titleLabel.stringValue = "마지막 보안 확인"
                bodyLabel.stringValue = "● 사용자 hook 설치됨\n○ lifecycle event·command 신뢰 필요\n\nCodex App 또는 CLI에서 새 task를 시작해 표시되는\nhook 정의를 검토·신뢰하세요.\nCLI에서는 /hooks로 검토 화면을 열 수 있습니다."
            }
        case .needsRepair:
            titleLabel.stringValue = "Codex 연결 복구가 필요해요"
            bodyLabel.stringValue = "● 로컬 수신기 준비됨\n○ 사용자 hook 또는 adapter 갱신 필요\n\n기존 Codex 설정은 보존됩니다.\n아래 버튼으로 agent-meong 항목만 복구하세요."
        case .invalidConfiguration:
            titleLabel.stringValue = "Codex hook 설정을 확인하세요"
            bodyLabel.stringValue = "~/.codex/hooks.json을 읽을 수 없습니다.\n기존 파일은 변경하지 않았습니다.\n\nJSON 형식을 수정한 뒤 앱을 다시 실행하세요."
        case let .unavailable(message):
            titleLabel.stringValue = "Codex 연결을 설치하지 못했어요"
            bodyLabel.stringValue = message
        }
    }

    @objc private func performAction() {
        if diagnostics.receiverError != nil {
            onRetry?()
        } else if diagnostics.rejectedEventCount > 0 {
            onInstall?()
        } else if diagnostics.hookInstallationState == .installed {
            onOpenCodex?()
        } else {
            onInstall?()
        }
    }

    @objc private func disconnect() {
        onUninstall?()
    }
}
