import Foundation

enum CodexHookInstallationState: Equatable {
    case checking
    case notInstalled
    case installed
    case needsRepair
    case invalidConfiguration
    case unavailable(String)
}

struct CodexHookInstaller {
    func status() -> CodexHookInstallationState {
        run("--status")
    }

    func install() -> CodexHookInstallationState {
        run("--install")
    }

    private func run(_ argument: String) -> CodexHookInstallationState {
        guard let adapterURL else {
            return .unavailable("앱에서 Codex adapter를 찾지 못했습니다.")
        }

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [adapterURL.path, argument]
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .unavailable(error.localizedDescription)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        guard
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let status = value["status"] as? String
        else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let message, !message.isEmpty {
                return .unavailable(message)
            }
            return .unavailable("Codex 연결 상태를 읽지 못했습니다.")
        }

        switch status {
        case "not_installed": return .notInstalled
        case "installed": return .installed
        case "needs_repair": return .needsRepair
        case "invalid": return .invalidConfiguration
        default:
            let message = value["message"] as? String ?? "Codex 연결을 변경하지 못했습니다."
            return .unavailable(message)
        }
    }

    private var adapterURL: URL? {
        let fileManager = FileManager.default
        if let bundled = Bundle.main.url(forResource: "codex_hook", withExtension: "py") {
            return bundled
        }

        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let candidates = [
            currentDirectory.appendingPathComponent("adapters/codex_hook.py"),
            currentDirectory.appendingPathComponent("../adapters/codex_hook.py").standardizedFileURL,
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}
