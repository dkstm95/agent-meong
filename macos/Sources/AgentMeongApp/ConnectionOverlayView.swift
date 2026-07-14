import AppKit

struct ConnectionDiagnostics {
    let receiverReady: Bool
    let lastEventAt: Date?
    let rejectedEventCount: Int
    let receiverError: String?
}

@MainActor
final class ConnectionOverlayView: NSView {
    var onRetry: (() -> Void)?

    private let chip = NSButton()
    private let sheet = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Codex")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let privacyLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "다시 시도", target: nil, action: nil)
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private var diagnostics = ConnectionDiagnostics(
        receiverReady: false,
        lastEventAt: nil,
        rejectedEventCount: 0,
        receiverError: nil
    )

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
        chip.contentTintColor = .white.withAlphaComponent(0.48)
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        chip.layer?.cornerRadius = 12
        chip.target = self
        chip.action = #selector(toggleSheet)
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

        [titleLabel, bodyLabel, privacyLabel, retryButton, closeButton].forEach {
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
        bodyLabel.textColor = .white.withAlphaComponent(0.67)
        bodyLabel.maximumNumberOfLines = 8
        privacyLabel.font = .systemFont(ofSize: 9.5)
        privacyLabel.textColor = .white.withAlphaComponent(0.38)
        privacyLabel.maximumNumberOfLines = 3
        retryButton.bezelStyle = .roundRect
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retry)
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 16, weight: .light)
        closeButton.contentTintColor = .white.withAlphaComponent(0.45)
        closeButton.target = self
        closeButton.action = #selector(closeSheet)
    }

    private func sheetConstraints() -> [NSLayoutConstraint] {
        [
            sheet.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            sheet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            sheet.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            sheet.heightAnchor.constraint(equalToConstant: 216),
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
            retryButton.trailingAnchor.constraint(equalTo: bodyLabel.trailingAnchor),
            retryButton.bottomAnchor.constraint(equalTo: privacyLabel.topAnchor, constant: -8),
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
        guard let lastEventAt = diagnostics.lastEventAt else {
            chip.title = "  ○  Codex · 실행 확인 필요  "
            return
        }
        chip.title = "  ●  Codex · \(relativeAge(from: lastEventAt, to: now))  "
    }

    private func updateSheet() {
        retryButton.isHidden = diagnostics.receiverError == nil
        if let error = diagnostics.receiverError {
            titleLabel.stringValue = "로컬 수신기를 열지 못했어요"
            bodyLabel.stringValue = "Codex 이벤트를 받을 수 없습니다.\n\n\(error)"
        } else if diagnostics.rejectedEventCount > 0 {
            titleLabel.stringValue = "Codex 이벤트 형식이 맞지 않아요"
            bodyLabel.stringValue = "장면은 변경하지 않았습니다.\nadapter와 앱 버전을 확인하세요.\n\n거절된 이벤트 · \(diagnostics.rejectedEventCount)개"
        } else if let date = diagnostics.lastEventAt {
            titleLabel.stringValue = "Codex"
            bodyLabel.stringValue = "● 로컬 수신기 준비됨\n● 이벤트 수신 확인됨\n마지막 이벤트 · \(exactTime(date))"
        } else {
            titleLabel.stringValue = "Codex의 움직임을 연결하세요"
            bodyLabel.stringValue = "● 로컬 수신기 준비됨\n○ 이벤트 수신 확인 필요\n\n1. Codex에서 /hooks 열기\n2. agent-meong hook 신뢰하기\n3. 새 task 시작하기"
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

    @objc private func retry() {
        onRetry?()
    }
}
