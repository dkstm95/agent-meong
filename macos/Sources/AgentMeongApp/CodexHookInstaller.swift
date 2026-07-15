import Darwin
import Foundation

enum CodexHookInstallationState: Equatable, Sendable {
    case checking
    case notInstalled
    case installed
    case needsRepair
    case invalidConfiguration
    case unavailable(String)
}

struct CodexHookInstaller: Sendable {
    func status() async -> CodexHookInstallationState {
        await runInBackground("--status")
    }

    func install() async -> CodexHookInstallationState {
        await runInBackground("--install")
    }

    func uninstall() async -> CodexHookInstallationState {
        await runInBackground("--uninstall")
    }

    private func runInBackground(_ argument: String) async -> CodexHookInstallationState {
        await Task.detached(priority: .utility) {
            run(argument)
        }.value
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
        } catch {
            return .unavailable(error.localizedDescription)
        }

        let deadline = Date.now.addingTimeInterval(3)
        while process.isRunning, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard !process.isRunning else {
            process.terminate()
            let terminationDeadline = Date.now.addingTimeInterval(0.5)
            while process.isRunning, Date.now < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            return .unavailable("Codex 연결 작업이 제시간에 끝나지 않았습니다.")
        }
        process.waitUntilExit()

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
