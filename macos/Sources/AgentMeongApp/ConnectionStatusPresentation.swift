import Foundation

enum ConnectionStatusKind: String {
    case checking
    case receiverError
    case invalidEvent
    case connectRequired
    case hooksDisabled
    case policyBlocked
    case updateRequired
    case invalidConfiguration
    case repairRequired
    case statusError
    case approvalRequired
    case hookDisabled
    case connectedRecent
    case waitingForEvent
    case waitingForActivity
    case runtimeUnavailable
}

struct ConnectionStatusPresentation {
    let kind: ConnectionStatusKind
    let menuLabel: String
    let chipTitle: String
    let accessibilityValue: String

    static func make(
        diagnostics: ConnectionDiagnostics,
        now: Date
    ) -> ConnectionStatusPresentation {
        let base = makeBase(diagnostics: diagnostics, now: now)
        guard diagnostics.inlineHooksPresent else { return base }
        return ConnectionStatusPresentation(
            kind: base.kind,
            menuLabel: base.menuLabel + "  ◇",
            chipTitle: base.chipTitle + "◇  ",
            accessibilityValue: base.accessibilityValue + L10n.text(
                ", config.toml hook도 함께 불러옴",
                "; config.toml hooks are also loaded"
            )
        )
    }

    private static func makeBase(
        diagnostics: ConnectionDiagnostics,
        now: Date
    ) -> ConnectionStatusPresentation {
        if diagnostics.receiverError != nil {
            return status(
                .receiverError,
                label: L10n.text("수신기 오류", "receiver error"),
                marker: "!",
                accessibilityValue: L10n.text("수신기 오류", "Receiver error")
            )
        }
        if diagnostics.rejectedEventCount > 0 {
            return status(
                .invalidEvent,
                label: L10n.text("형식 확인", "check format"),
                marker: "!",
                accessibilityValue: L10n.text(
                    "이벤트 형식 확인 필요",
                    "Event format needs attention"
                )
            )
        }

        if diagnostics.hookProblemShouldLead,
            let presentation = hookProblem(diagnostics.hookInstallationState)
        {
            return presentation
        }

        if diagnostics.managedHookPresent {
            switch diagnostics.hookRuntimeStatus {
            case .disabled:
                return status(
                    .hookDisabled,
                    label: L10n.text("hook 꺼짐", "hook disabled"),
                    marker: "!",
                    accessibilityValue: L10n.text(
                        "일부 agent-meong hook이 꺼짐",
                        "Some agent-meong hooks are disabled"
                    )
                )
            case .reviewRequired:
                return status(
                    .approvalRequired,
                    label: L10n.text("승인 필요", "approval needed"),
                    marker: "○",
                    accessibilityValue: L10n.text(
                        "Codex hook 사용자 승인 필요",
                        "Codex hook review required"
                    )
                )
            case .checking, .ready, .unavailable:
                break
            }
        }

        if let lastEventAt = diagnostics.lastEventAt {
            let age = L10n.relativeAge(from: lastEventAt, to: now)
            return status(
                .connectedRecent,
                label: diagnostics.hasOnlySeparateConnection
                    ? L10n.text("별도 · \(age)", "separate · \(age)")
                    : age,
                marker: "●",
                accessibilityValue: diagnostics.hasOnlySeparateConnection
                    ? L10n.text(
                        "별도 CODEX_HOME 연결됨, 마지막 이벤트 \(age), 기본 ~/.codex 연결 안 됨",
                        "Separate CODEX_HOME connected; last event \(age); default ~/.codex not connected"
                    )
                    : L10n.text(
                        "연결됨, 마지막 이벤트 \(age)",
                        "Connected; last event \(age)"
                    )
            )
        }
        if diagnostics.previouslyConfirmedAt != nil,
            !diagnostics.hookProblemOverridesHistory
        {
            return status(
                .waitingForEvent,
                label: diagnostics.hasOnlySeparateConnection
                    ? L10n.text("별도 이벤트 대기", "separate waiting")
                    : L10n.text("이벤트 대기", "waiting for event"),
                marker: "○",
                accessibilityValue: diagnostics.hasOnlySeparateConnection
                    ? L10n.text(
                        "별도 CODEX_HOME 연결됨, 이벤트 대기 중, 기본 ~/.codex 연결 안 됨",
                        "Separate CODEX_HOME connected; waiting for an event; default ~/.codex not connected"
                    )
                    : L10n.text(
                        "연결됨, 이벤트 대기 중",
                        "Connected; waiting for an event"
                    )
            )
        }
        if diagnostics.managedHookPresent,
            diagnostics.hookInstallationState == .installed,
            diagnostics.hookRuntimeStatus == .ready
        {
            return status(
                .waitingForActivity,
                label: L10n.text("활동 대기", "waiting for activity"),
                marker: "○",
                accessibilityValue: L10n.text(
                    "Codex hook 준비됨, 첫 활동 대기 중",
                    "Codex hooks ready; waiting for the first activity"
                )
            )
        }
        if diagnostics.managedHookPresent,
            diagnostics.hookInstallationState == .installed,
            diagnostics.hookRuntimeStatus == .unavailable
        {
            return status(
                .runtimeUnavailable,
                label: L10n.text("상태 확인", "check status"),
                marker: "!",
                accessibilityValue: L10n.text(
                    "Codex hook 런타임 상태를 확인하지 못함",
                    "Could not read the Codex hook runtime status"
                )
            )
        }
        if let presentation = hookProblem(diagnostics.hookInstallationState) {
            return presentation
        }
        return status(
            .checking,
            label: L10n.text("확인 중", "checking"),
            marker: "○",
            accessibilityValue: L10n.text(
                "Codex 연결 확인 중",
                "Checking the Codex connection"
            )
        )
    }

    private static func hookProblem(
        _ state: CodexHookInstallationState
    ) -> ConnectionStatusPresentation? {
        switch state {
        case .notInstalled:
            status(
                .connectRequired,
                label: L10n.text("연결 필요", "connect"),
                marker: "○",
                accessibilityValue: L10n.text("연결 필요", "Connection required")
            )
        case .hooksDisabled:
            status(
                .hooksDisabled,
                label: L10n.text("hooks 꺼짐", "hooks off"),
                marker: "!",
                accessibilityValue: L10n.text(
                    "Codex hooks 비활성화",
                    "Codex hooks are disabled"
                )
            )
        case .managedHooksOnly:
            status(
                .policyBlocked,
                label: L10n.text("정책 제한", "policy blocked"),
                marker: "!",
                accessibilityValue: L10n.text(
                    "관리형 hooks 정책 제한",
                    "Managed-hooks-only policy"
                )
            )
        case .newerVersion:
            status(
                .updateRequired,
                label: L10n.text("앱 업데이트", "update app"),
                marker: "!",
                accessibilityValue: L10n.text(
                    "agent-meong 앱 업데이트 필요",
                    "Update agent-meong"
                )
            )
        case .invalidConfiguration:
            status(
                .invalidConfiguration,
                label: L10n.text("설정 확인", "check config"),
                marker: "!",
                accessibilityValue: L10n.text(
                    "Codex hook 설정 확인 필요",
                    "Check the Codex hook configuration"
                )
            )
        case .needsRepair:
            status(
                .repairRequired,
                label: L10n.text("복구 필요", "repair"),
                marker: "!",
                accessibilityValue: L10n.text(
                    "Codex 연결 복구 필요",
                    "Repair the Codex connection"
                )
            )
        case .unavailable:
            status(
                .statusError,
                label: L10n.text("상태 오류", "status error"),
                marker: "!",
                accessibilityValue: L10n.text(
                    "Codex 연결 상태 오류",
                    "Codex connection status error"
                )
            )
        case .checking, .installed:
            nil
        }
    }

    private static func status(
        _ kind: ConnectionStatusKind,
        label: String,
        marker: String,
        accessibilityValue: String
    ) -> ConnectionStatusPresentation {
        ConnectionStatusPresentation(
            kind: kind,
            menuLabel: "Codex · \(label)",
            chipTitle: "  \(marker)  Codex · \(label)  ",
            accessibilityValue: accessibilityValue
        )
    }
}
