import AgentMeongCore
import Foundation

enum MeongLanguage: String, Sendable {
    case korean = "ko"
    case english = "en"
}

enum L10n {
    static var language: MeongLanguage {
        resolveLanguage(
            override: ProcessInfo.processInfo.environment["AGENT_MEONG_LANGUAGE"],
            preferredLanguages: Locale.preferredLanguages
        )
    }

    static var locale: Locale {
        Locale(identifier: language == .korean ? "ko_KR" : "en_US")
    }

    static func resolveLanguage(
        override: String?,
        preferredLanguages: [String]
    ) -> MeongLanguage {
        switch override?.lowercased() {
        case "ko": return .korean
        case "en": return .english
        default: break
        }

        guard let preferred = preferredLanguages.first?.lowercased() else {
            return .english
        }
        return preferred == "ko"
            || preferred.hasPrefix("ko-")
            || preferred.hasPrefix("ko_")
            ? .korean
            : .english
    }

    static func text(_ korean: String, _ english: String) -> String {
        language == .korean ? korean : english
    }

    static func relativeAge(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 { return text("방금", "just now") }
        if seconds < 60 { return text("\(seconds)초 전", "\(seconds)s ago") }
        if seconds < 3_600 {
            return text("\(seconds / 60)분 전", "\(seconds / 60)m ago")
        }
        return text("\(seconds / 3_600)시간 전", "\(seconds / 3_600)h ago")
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    static func stateLabel(_ state: VisualState) -> String {
        switch state {
        case .quiet: text("고요함", "Quiet")
        case .active: text("활동 중", "Active")
        case .attention: text("확인 필요", "Needs attention")
        case .uncertain: text("상태 불확실", "Uncertain")
        case .finished: text("종료됨", "Finished")
        case .completed: text("완료", "Completed")
        case .cancelled: text("취소됨", "Cancelled")
        case .failed: text("실패 확인 필요", "Failure reported")
        }
    }
}
