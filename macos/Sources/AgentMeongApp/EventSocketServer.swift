import AgentMeongCore
import Darwin
import Foundation

private struct SocketPathIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

final class EventSocketServer: @unchecked Sendable {
    static var defaultPath: String {
        "/tmp/agent-meong-\(getuid()).sock"
    }

    let path: String

    private let queue = DispatchQueue(label: "dev.ailab.agent-meong.events")
    private let onObservation: @MainActor @Sendable (ActivityObservation) -> Void
    private let onRejected: @MainActor @Sendable (String) -> Void
    private var descriptor: Int32 = -1
    private var lockDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var ownsSocketPath = false
    private var ownedSocketIdentity: SocketPathIdentity?

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
        try acquireOwnershipLock()
        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            let code = errno
            releaseOwnershipLock()
            throw SocketError.systemCall("socket", code)
        }

        do {
            try bindAndListen(socketDescriptor)
            descriptor = socketDescriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: socketDescriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPendingConnections() }
            readSource = source
            source.resume()
        } catch {
            close(socketDescriptor)
            removeOwnedSocketPath()
            releaseOwnershipLock()
            throw error
        }
    }

    func stop() {
        let socketDescriptor = descriptor
        descriptor = -1
        readSource?.cancel()
        readSource = nil
        if socketDescriptor >= 0 {
            close(socketDescriptor)
        }
        removeOwnedSocketPath()
        releaseOwnershipLock()
    }

    deinit {
        stop()
    }

    private func bindAndListen(_ socketDescriptor: Int32) throws {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw SocketError.pathTooLong
        }

        var bindResult = bindSocket(socketDescriptor)
        if bindResult != 0, errno == EADDRINUSE {
            if existingSocketIsLive() {
                throw SocketError.alreadyRunning
            }
            guard existingPathIsOwnedSocket() else {
                throw SocketError.unsafeExistingPath
            }
            guard unlink(path) == 0 else {
                throw SocketError.systemCall("unlink", errno)
            }
            bindResult = bindSocket(socketDescriptor)
        }
        guard bindResult == 0 else { throw SocketError.systemCall("bind", errno) }
        ownsSocketPath = true
        ownedSocketIdentity = socketPathIdentityIfOwned()
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

    private func bindSocket(_ socketDescriptor: Int32) -> Int32 {
        withSocketAddress { socketAddress, length in
            Darwin.bind(socketDescriptor, socketAddress, length)
        }
    }

    private var lockPath: String { "\(path).lock" }

    private func acquireOwnershipLock() throws {
        let fileDescriptor = Darwin.open(
            lockPath,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard fileDescriptor >= 0 else {
            throw SocketError.systemCall("open lock", errno)
        }

        var information = stat()
        guard fstat(fileDescriptor, &information) == 0 else {
            let code = errno
            close(fileDescriptor)
            throw SocketError.systemCall("fstat lock", code)
        }
        guard
            information.st_uid == getuid(),
            (information.st_mode & S_IFMT) == S_IFREG
        else {
            close(fileDescriptor)
            throw SocketError.unsafeExistingPath
        }
        guard fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            close(fileDescriptor)
            throw SocketError.systemCall("chmod lock", code)
        }
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fileDescriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw SocketError.alreadyRunning
            }
            throw SocketError.systemCall("flock", code)
        }
        lockDescriptor = fileDescriptor
    }

    private func releaseOwnershipLock() {
        guard lockDescriptor >= 0 else { return }
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }

    private func existingSocketIsLive() -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        return withSocketAddress { socketAddress, length in
            Darwin.connect(probe, socketAddress, length)
        } == 0
    }

    private func existingPathIsOwnedSocket() -> Bool {
        socketPathIdentityIfOwned() != nil
    }

    private func socketPathIdentityIfOwned() -> SocketPathIdentity? {
        var information = stat()
        guard
            lstat(path, &information) == 0,
            information.st_uid == getuid(),
            (information.st_mode & S_IFMT) == S_IFSOCK
        else { return nil }
        return SocketPathIdentity(device: information.st_dev, inode: information.st_ino)
    }

    private func withSocketAddress<T>(
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
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

    private func removeOwnedSocketPath() {
        guard ownsSocketPath else { return }
        ownsSocketPath = false
        let identity = ownedSocketIdentity
        ownedSocketIdentity = nil
        if identity != nil, socketPathIdentityIfOwned() == identity {
            unlink(path)
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
    case alreadyRunning
    case unsafeExistingPath
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong:
            "Unix socket path is too long"
        case .alreadyRunning:
            "agent-meong is already receiving events"
        case .unsafeExistingPath:
            "Socket or lock path is occupied by a file agent-meong does not own"
        case let .systemCall(name, code):
            "\(name) failed: \(String(cString: strerror(code)))"
        }
    }
}
