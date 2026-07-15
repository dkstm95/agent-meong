import Foundation

public struct WorldCheckpointStore: Sendable {
    public let fileURL: URL
    private let maximumByteCount: Int

    public init(fileURL: URL, maximumByteCount: Int = 1_048_576) {
        self.fileURL = fileURL
        self.maximumByteCount = max(1, maximumByteCount)
    }

    public func load() throws -> WorldCheckpoint? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard
            let size = attributes[.size] as? NSNumber,
            size.intValue <= maximumByteCount
        else { throw WorldCheckpointStoreError.checkpointTooLarge }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        return try JSONDecoder().decode(WorldCheckpoint.self, from: data)
    }

    public func save(_ state: WorldState) throws {
        do {
            try replaceCheckpoint(with: state)
        } catch {
            // Never leave an older live snapshot behind after a failed update.
            // A missing checkpoint is safer than reviving stale activity.
            try? clear()
            throw error
        }
    }

    private func replaceCheckpoint(with state: WorldState) throws {
        let checkpoint = WorldCheckpoint(state: state)
        guard !checkpoint.actors.isEmpty else {
            try clear()
            return
        }
        let data = try JSONEncoder().encode(checkpoint)
        guard data.count <= maximumByteCount else {
            throw WorldCheckpointStoreError.checkpointTooLarge
        }

        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    public func clear() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}

public enum WorldCheckpointStoreError: Error, Equatable {
    case checkpointTooLarge
}
