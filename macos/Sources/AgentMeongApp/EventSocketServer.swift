import AgentMeongCore
import Darwin
import Foundation

final class EventSocketServer: @unchecked Sendable {
    static var defaultPath: String {
        "/tmp/agent-meong-\(getuid()).sock"
    }

    let path: String

    private let queue = DispatchQueue(label: "dev.ailab.agent-meong.events")
    private let onObservation: @MainActor @Sendable (ActivityObservation) -> Void
    private let onRejected: @MainActor @Sendable (String) -> Void
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?

    init(
        path: String = EventSocketServer.defaultPath,
        onObservation: @escaping @MainActor @Sendable (ActivityObservation) -> Void,
        onRejected: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.path = path
        self.onObservation = onObservation
        self.onRejected = onRejected
    }

    func start() throws {
        guard descriptor == -1 else { return }
        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw SocketError.systemCall("socket", errno) }

        do {
            try bindAndListen(socketDescriptor)
            descriptor = socketDescriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: socketDescriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPendingConnections() }
            source.setCancelHandler { close(socketDescriptor) }
            readSource = source
            source.resume()
        } catch {
            close(socketDescriptor)
            unlink(path)
            throw error
        }
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        descriptor = -1
        unlink(path)
    }

    deinit {
        stop()
    }

    private func bindAndListen(_ socketDescriptor: Int32) throws {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw SocketError.pathTooLong
        }

        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = path.utf8CString.map { UInt8(bitPattern: $0) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    socketDescriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0 else { throw SocketError.systemCall("bind", errno) }
        guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
            throw SocketError.systemCall("chmod", errno)
        }
        guard listen(socketDescriptor, 16) == 0 else {
            throw SocketError.systemCall("listen", errno)
        }
        guard fcntl(socketDescriptor, F_SETFL, O_NONBLOCK) != -1 else {
            throw SocketError.systemCall("fcntl", errno)
        }
    }

    private func acceptPendingConnections() {
        while descriptor >= 0 {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            receive(from: client)
            close(client)
        }
    }

    private func receive(from client: Int32) {
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count < 65_536 {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(client, bytes.baseAddress, bytes.count)
            }
            guard count > 0 else { break }
            data.append(buffer, count: count)
            if buffer[..<count].contains(10) { break }
        }
        decodeLines(in: data)
    }

    private func decodeLines(in data: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in data.split(separator: 10) {
            guard let observation = try? decoder.decode(ActivityObservation.self, from: Data(line)) else {
                Task { @MainActor [onRejected] in
                    onRejected("schemaVersion 또는 필수 필드 불일치")
                }
                continue
            }
            Task { @MainActor [onObservation] in
                onObservation(observation)
            }
        }
    }
}

private enum SocketError: LocalizedError {
    case pathTooLong
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong:
            "Unix socket path is too long"
        case let .systemCall(name, code):
            "\(name) failed: \(String(cString: strerror(code)))"
        }
    }
}
