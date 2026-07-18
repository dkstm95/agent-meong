import CryptoKit
import Darwin
import Foundation

private let integrationVersion = "dev.ailab.agent-meong/v6"
private let observationSource = "openai.codex"
private let instancePattern = try! NSRegularExpression(pattern: "^[0-9a-f]{24}$")
private let maximumHookPayloadBytes = 16 * 1_024 * 1_024

private let eventKinds = [
    "UserPromptSubmit": "turn.started",
    "PreToolUse": "tool.started",
    "PermissionRequest": "approval.waiting",
    "PostToolUse": "tool.finished",
    "SubagentStart": "agent.started",
    "SubagentStop": "agent.finished",
    "Stop": "turn.stopping",
]

private struct Options {
    var printOnly = false
    var integrationInstance: String?
    var occurredAt: String?
    var eventID: String?

    static func parse(_ arguments: [String]) -> Options? {
        var result = Options()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--print":
                result.printOnly = true
                index += 1
            case "--integration-instance", "--occurred-at", "--event-id":
                guard index + 1 < arguments.count else { return nil }
                let value = arguments[index + 1]
                switch arguments[index] {
                case "--integration-instance":
                    guard isInstanceID(value) else { return nil }
                    result.integrationInstance = value
                case "--occurred-at": result.occurredAt = value
                default: result.eventID = value
                }
                index += 2
            default:
                return nil
            }
        }
        return result
    }
}

private func isInstanceID(_ value: String) -> Bool {
    instancePattern.firstMatch(
        in: value,
        range: NSRange(value.startIndex..., in: value)
    ) != nil
}

private func hexDigest(_ values: [String]) -> String {
    let digest = SHA256.hash(data: Data(values.joined(separator: "\0").utf8))
    return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
}

private func opaqueID(_ kind: String, _ values: String...) -> String {
    hexDigest([kind] + values)
}

private func stringValue(_ value: Any?) -> String? {
    let result: String
    switch value {
    case let value as String:
        result = value
    case let value as Bool:
        result = value ? "True" : "False"
    case let value as NSNumber:
        let type = String(cString: value.objCType)
        guard !["f", "d"].contains(type) else { return nil }
        result = value.stringValue
    default:
        return nil
    }
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func toolCategory(_ value: Any?) -> String {
    let name = String(describing: value ?? "").lowercased()
    if ["bash", "shell", "exec", "terminal"].contains(where: name.contains) {
        return "shell"
    }
    if ["apply_patch", "edit", "write"].contains(where: name.contains) {
        return "edit"
    }
    if ["browser", "chrome", "web"].contains(where: name.contains) {
        return "browser"
    }
    if ["search", "find", "grep", "read"].contains(where: name.contains) {
        return "search"
    }
    return "other"
}

private func mainActorID(instance: String, session: String) -> String {
    opaqueID("actor.main", instance, session)
}

private func stableEventID(
    payload: [String: Any],
    eventName: String,
    instance: String,
    session: String
) -> String {
    let turnID = stringValue(payload["turn_id"])
    let agentID = stringValue(payload["agent_id"])
    let toolUseID = stringValue(payload["tool_use_id"])
    let stable = (["UserPromptSubmit", "Stop"].contains(eventName) && turnID != nil)
        || (["SubagentStart", "SubagentStop"].contains(eventName) && agentID != nil)
        || (["PreToolUse", "PostToolUse"].contains(eventName) && toolUseID != nil)
    guard stable else {
        return opaqueID("event.random", instance, UUID().uuidString.lowercased())
    }
    return opaqueID(
        "event",
        instance,
        session,
        turnID ?? "",
        agentID ?? "",
        toolUseID ?? "",
        eventName
    )
}

private func currentTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: Date())
}

private func normalize(
    _ payload: [String: Any],
    instance: String,
    occurredAt: String,
    suppliedEventID: String?
) -> [String: Any]? {
    guard
        let eventName = stringValue(payload["hook_event_name"]),
        let kind = eventKinds[eventName],
        let rawSessionID = stringValue(payload["session_id"])
    else { return nil }

    var actorID = mainActorID(instance: instance, session: rawSessionID)
    var parentActorID: String?
    let agentID = stringValue(payload["agent_id"])
    if ["SubagentStart", "SubagentStop"].contains(eventName), agentID == nil {
        return nil
    }
    if let agentID {
        actorID = opaqueID("actor.agent", instance, rawSessionID, agentID)
        parentActorID = mainActorID(instance: instance, session: rawSessionID)
    }

    let rawTurnID = stringValue(payload["turn_id"])
    let scopeID = rawTurnID.map {
        opaqueID("turn", instance, rawSessionID, $0)
    }
    let eventID = suppliedEventID.map {
        opaqueID("event.supplied", instance, $0)
    } ?? stableEventID(
        payload: payload,
        eventName: eventName,
        instance: instance,
        session: rawSessionID
    )

    var observation: [String: Any] = [
        "schemaVersion": 0,
        "eventId": eventID,
        "source": observationSource,
        "sessionId": opaqueID("session", instance, rawSessionID),
        "actorId": actorID,
        "occurredAt": occurredAt,
        "kind": kind,
        "integrationVersion": integrationVersion,
        "integrationInstance": instance,
    ]
    if let parentActorID { observation["parentActorId"] = parentActorID }
    if let scopeID { observation["scopeId"] = scopeID }
    if ["PreToolUse", "PostToolUse", "PermissionRequest"].contains(eventName) {
        observation["toolCategory"] = toolCategory(payload["tool_name"])
    }
    return observation
}

private func readInstalledInstance() -> String? {
    // The executable is copied beside the opaque instance file. Reading that
    // adjacent file keeps the namespace bound to the definition Codex actually
    // launched, even if HOME or CODEX_HOME in its environment changes later.
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        .standardizedFileURL.resolvingSymlinksInPath()
    let directory = executable.deletingLastPathComponent()
    guard
        executable.lastPathComponent == "codex_hook_forwarder",
        directory.deletingLastPathComponent().lastPathComponent == "codex-hooks",
        isInstanceID(directory.lastPathComponent)
    else { return nil }
    let descriptor = Darwin.open(
        directory.path,
        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
    )
    guard descriptor >= 0 else { return nil }
    defer { Darwin.close(descriptor) }
    let fileDescriptor = openat(descriptor, ".instance-id", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fileDescriptor >= 0 else { return nil }
    defer { Darwin.close(fileDescriptor) }
    var information = stat()
    guard
        fstat(fileDescriptor, &information) == 0,
        (information.st_mode & S_IFMT) == S_IFREG,
        information.st_size <= 128
    else { return nil }
    var bytes = [UInt8](repeating: 0, count: 128)
    let count = Darwin.read(fileDescriptor, &bytes, bytes.count)
    guard count >= 0 else { return nil }
    let value = String(decoding: bytes.prefix(count), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return isInstanceID(value) ? value : nil
}

private var socketPath: String {
    ProcessInfo.processInfo.environment["AGENT_MEONG_SOCKET"]
        ?? "/tmp/agent-meong-\(getuid()).sock"
}

private func endpointIsOwnedSocket(_ path: String) -> Bool {
    var information = stat()
    return lstat(path, &information) == 0
        && information.st_uid == getuid()
        && (information.st_mode & S_IFMT) == S_IFSOCK
}

private func withSocketAddress<T>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
) -> T? {
    guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
        return nil
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = path.utf8CString.map { UInt8(bitPattern: $0) }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
    }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func reportDeliveryFailure(_ reason: String) {
    guard ProcessInfo.processInfo.environment[
        "AGENT_MEONG_E2E_DELIVERY_DIAGNOSTICS"
    ] == "1" else { return }
    FileHandle.standardError.write(Data("agent-meong delivery failed: \(reason)\n".utf8))
}

private func readStandardInput(retainingAtMost maximumByteCount: Int) -> Data? {
    var retained = Data()
    var exceededLimit = false
    while true {
        let chunk: Data
        do {
            guard
                let next = try FileHandle.standardInput.read(upToCount: 65_536),
                !next.isEmpty
            else { break }
            chunk = next
        } catch {
            return nil
        }
        if !exceededLimit {
            if chunk.count > maximumByteCount - retained.count {
                retained.removeAll(keepingCapacity: false)
                exceededLimit = true
            } else {
                retained.append(chunk)
            }
        }
    }
    return exceededLimit ? nil : retained
}

private func connectWithDeadline(_ descriptor: Int32, path: String) -> Bool {
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        return false
    }
    let result = withSocketAddress(path: path) {
        Darwin.connect(descriptor, $0, $1)
    }
    if result == 0 {
        return fcntl(descriptor, F_SETFL, flags) == 0
    }
    guard errno == EINPROGRESS else { return false }

    var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
    guard poll(&pending, 1, 150) == 1 else { return false }
    var socketError: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(
        descriptor,
        SOL_SOCKET,
        SO_ERROR,
        &socketError,
        &length
    ) == 0 else { return false }
    return socketError == 0 && fcntl(descriptor, F_SETFL, flags) == 0
}

private func send(_ observation: [String: Any], path: String) -> Bool {
    guard endpointIsOwnedSocket(path) else {
        reportDeliveryFailure("endpoint_missing")
        return false
    }
    guard let encoded = try? JSONSerialization.data(withJSONObject: observation) else {
        return false
    }
    let message = encoded + Data([10])

    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        reportDeliveryFailure("connect_failed")
        return false
    }
    defer { Darwin.close(descriptor) }
    var noSignal: Int32 = 1
    setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSignal,
        socklen_t(MemoryLayout<Int32>.size)
    )
    var timeout = timeval(tv_sec: 0, tv_usec: 150_000)
    setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_SNDTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    )
    guard connectWithDeadline(descriptor, path: path) else {
        reportDeliveryFailure("connect_failed")
        return false
    }
    var peerUserID = uid_t()
    var peerGroupID = gid_t()
    guard getpeereid(descriptor, &peerUserID, &peerGroupID) == 0,
          peerUserID == getuid()
    else {
        reportDeliveryFailure("peer_mismatch")
        return false
    }

    let sentAll = message.withUnsafeBytes { buffer -> Bool in
        guard let base = buffer.baseAddress else { return false }
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.send(descriptor, base.advanced(by: offset), buffer.count - offset, 0)
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }
    if !sentAll { reportDeliveryFailure("connect_failed") }
    return sentAll
}

@main
private enum AgentMeongCodexForwarder {
    static func main() {
        guard let options = Options.parse(Array(CommandLine.arguments.dropFirst())) else {
            exit(2)
        }

        let environment = ProcessInfo.processInfo.environment
        let requiresDelivery = environment["AGENT_MEONG_E2E_REQUIRE_DELIVERY"] == "1"
        let diagnostics = environment["AGENT_MEONG_E2E_DELIVERY_DIAGNOSTICS"] == "1"
        if !options.printOnly, !requiresDelivery, !diagnostics,
           !endpointIsOwnedSocket(socketPath) {
            // Consume stdin in bounded chunks so Codex never observes EPIPE
            // while it is still writing. The inactive path neither parses nor
            // retains the raw payload.
            _ = readStandardInput(retainingAtMost: 0)
            return
        }

        guard
            let input = readStandardInput(retainingAtMost: maximumHookPayloadBytes),
            let value = try? JSONSerialization.jsonObject(with: input),
            let payload = value as? [String: Any]
        else { return }
        let instance = options.integrationInstance ?? readInstalledInstance() ?? "unscoped"
        guard let observation = normalize(
            payload,
            instance: instance,
            occurredAt: options.occurredAt ?? currentTimestamp(),
            suppliedEventID: options.eventID
        ) else { return }

        if options.printOnly {
            if let data = try? JSONSerialization.data(withJSONObject: observation) {
                FileHandle.standardOutput.write(data + Data([10]))
            }
            return
        }
        if !send(observation, path: socketPath), requiresDelivery {
            exit(1)
        }
    }
}
