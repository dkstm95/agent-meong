import AppKit
import Darwin
import Foundation

enum CodexReviewLaunchState: Equatable, Sendable {
    case idle
    case opening
    case opened
    case failed
}

@MainActor
struct CodexReviewLauncher {
    func open() async -> Bool {
        if ProcessInfo.processInfo.environment["AGENT_MEONG_E2E_REPORT"] != nil {
            return ProcessInfo.processInfo.environment[
                "AGENT_MEONG_E2E_REVIEW_LAUNCH_FAIL"
            ] != "1"
        }

        guard
            let launcher = Bundle.main.url(
                forResource: "open-codex-hook-review",
                withExtension: "command"
            ),
            FileManager.default.isExecutableFile(atPath: launcher.path)
        else { return false }

        guard await canResolveCodex(using: launcher) else { return false }

        let terminal = URL(
            fileURLWithPath: "/System/Applications/Utilities/Terminal.app",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: terminal.path) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [launcher],
                withApplicationAt: terminal,
                configuration: configuration
            ) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private func canResolveCodex(using launcher: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // The command bounds each capability probe at three seconds
                // and may need to skip one or more independently updated app
                // or CLI candidates before reaching a compatible fallback.
                // Keep a global ceiling without cutting off that fallback.
                let timeout: TimeInterval = 40
                let process = Process()
                process.executableURL = launcher
                process.arguments = ["--check"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let deadline = Date().addingTimeInterval(timeout)
                    while process.isRunning, Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    guard !process.isRunning else {
                        process.terminate()
                        let terminationDeadline = Date().addingTimeInterval(0.5)
                        while process.isRunning, Date() < terminationDeadline {
                            Thread.sleep(forTimeInterval: 0.02)
                        }
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                        process.waitUntilExit()
                        continuation.resume(returning: false)
                        return
                    }
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
