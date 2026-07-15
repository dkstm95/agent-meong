import Foundation

struct E2EReporter {
    private let reportPath = ProcessInfo.processInfo.environment["AGENT_MEONG_E2E_REPORT"]

    func record(_ event: String, fields: [String: Any] = [:]) {
        guard let reportPath else { return }
        var payload = fields
        payload["event"] = event
        guard
            JSONSerialization.isValidJSONObject(payload),
            var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return }
        data.append(10)

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: reportPath) {
            _ = fileManager.createFile(atPath: reportPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: reportPath) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }
}
