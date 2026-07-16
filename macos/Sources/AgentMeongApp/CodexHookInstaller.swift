import Darwin
import Foundation

enum CodexHookInstallationState: Equatable, Sendable {
    case checking
    case notInstalled
    case installed
    case needsRepair
    case invalidConfiguration
    case hooksDisabled
    case managedHooksOnly
    case newerVersion
    case unavailable(String)
}

struct CodexHookInstallationResult: Equatable, Sendable {
    let state: CodexHookInstallationState
    let inlineHooksPresent: Bool
    let managedHookPresent: Bool
    let definitionID: String?
    let instanceID: String?
}

struct CodexHookInstaller: Sendable {
    func status() async -> CodexHookInstallationResult {
        await runInBackground("--status")
    }

    func install() async -> CodexHookInstallationResult {
        await runInBackground("--install")
    }

    func uninstall() async -> CodexHookInstallationResult {
        await runInBackground("--uninstall")
    }

    private func runInBackground(_ argument: String) async -> CodexHookInstallationResult {
        await Task.detached(priority: .utility) {
            run(argument)
        }.value
    }

    private func run(_ argument: String) -> CodexHookInstallationResult {
        guard let adapterURL else {
            return result(.unavailable(
                L10n.text(
                    "앱에서 Codex adapter를 찾지 못했습니다.",
                    "The app could not find the Codex adapter."
                )
            ))
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
            return result(.unavailable(
                L10n.text(
                    "Codex adapter를 실행하지 못했습니다.",
                    "The Codex adapter could not be started."
                )
            ))
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
            return result(.unavailable(
                L10n.text(
                    "Codex 연결 작업이 제시간에 끝나지 않았습니다.",
                    "The Codex connection operation timed out."
                )
            ))
        }
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        guard
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let status = value["status"] as? String
        else {
            _ = errorData
            return result(.unavailable(
                L10n.text(
                    "Codex 연결 상태를 읽지 못했습니다.",
                    "The Codex connection status could not be read."
                )
            ))
        }

        let inlineHooksPresent = (value["warnings"] as? [String] ?? [])
            .contains("inline_hooks_present")
        let state: CodexHookInstallationState = switch status {
        case "not_installed": .notInstalled
        case "installed": .installed
        case "needs_repair": .needsRepair
        case "invalid": .invalidConfiguration
        case "hooks_disabled": .hooksDisabled
        case "managed_hooks_only": .managedHooksOnly
        case "newer_version": .newerVersion
        default: .unavailable(
            L10n.text(
                "Codex 연결을 변경하지 못했습니다.",
                "The Codex connection could not be changed."
            )
        )
        }
        return result(
            state,
            inlineHooksPresent: inlineHooksPresent,
            managedHookPresent: value["managedHookPresent"] as? Bool ?? false,
            definitionID: value["definitionId"] as? String,
            instanceID: value["instanceId"] as? String
        )
    }

    private func result(
        _ state: CodexHookInstallationState,
        inlineHooksPresent: Bool = false,
        managedHookPresent: Bool = false,
        definitionID: String? = nil,
        instanceID: String? = nil
    ) -> CodexHookInstallationResult {
        CodexHookInstallationResult(
            state: state,
            inlineHooksPresent: inlineHooksPresent,
            managedHookPresent: managedHookPresent,
            definitionID: definitionID,
            instanceID: instanceID
        )
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
