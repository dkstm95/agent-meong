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

enum CodexHookRuntimeStatus: String, Equatable, Sendable {
    case checking
    case ready
    case reviewRequired = "review_required"
    case disabled
    case unavailable
}

struct CodexHookInstallationResult: Equatable, Sendable {
    let state: CodexHookInstallationState
    let inlineHooksPresent: Bool
    let managedHookPresent: Bool
    let definitionID: String?
    let instanceID: String?
    let runtimeStatus: CodexHookRuntimeStatus
    let runtimeProblemEvents: [String]
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
        let result = await Task.detached(priority: .utility) {
            run(argument)
        }.value
        if argument == "--status", let delay = statusResultDelayForE2E {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return result
    }

    private var statusResultDelayForE2E: TimeInterval? {
        guard
            ProcessInfo.processInfo.environment["AGENT_MEONG_E2E_REPORT"] != nil,
            let rawValue = ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_HOOK_STATUS_RESULT_DELAY"
            ],
            let delay = TimeInterval(rawValue),
            delay.isFinite,
            delay >= 0.02,
            delay <= 2
        else { return nil }
        return delay
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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [adapterURL.path, argument]
        var environment = ProcessInfo.processInfo.environment
        // The in-app connection controls are explicitly for the default
        // user home. A CODEX_HOME inherited from launchctl or a developer
        // shell must not silently redirect Connect, status, or Disconnect.
        environment.removeValue(forKey: "CODEX_HOME")
        // Source-only tests may select a freshly built helper explicitly, but
        // the packaged app must always install its own signed bundled helper.
        // Never inherit a launchctl or shell override into the user hook.
        environment.removeValue(forKey: "AGENT_MEONG_FORWARDER_SOURCE")
        environment["AGENT_MEONG_RUNTIME_DIAGNOSTICS"] = "1"
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

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

        // The adapter may prewarm the native forwarder twice and then run two
        // independently bounded app-server phases for each product candidate.
        // Keep the entire path bounded while leaving explicit scheduling and
        // file-I/O slack beyond those inner deadlines.
        let deadline = Date.now.addingTimeInterval(40)
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
        guard
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let status = value["status"] as? String
        else {
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
            instanceID: value["instanceId"] as? String,
            runtimeStatus: CodexHookRuntimeStatus(
                rawValue: value["runtimeStatus"] as? String ?? "unavailable"
            ) ?? .unavailable,
            runtimeProblemEvents: value["runtimeProblemEvents"] as? [String] ?? []
        )
    }

    private func result(
        _ state: CodexHookInstallationState,
        inlineHooksPresent: Bool = false,
        managedHookPresent: Bool = false,
        definitionID: String? = nil,
        instanceID: String? = nil,
        runtimeStatus: CodexHookRuntimeStatus = .unavailable,
        runtimeProblemEvents: [String] = []
    ) -> CodexHookInstallationResult {
        CodexHookInstallationResult(
            state: state,
            inlineHooksPresent: inlineHooksPresent,
            managedHookPresent: managedHookPresent,
            definitionID: definitionID,
            instanceID: instanceID,
            runtimeStatus: runtimeStatus,
            runtimeProblemEvents: runtimeProblemEvents
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
