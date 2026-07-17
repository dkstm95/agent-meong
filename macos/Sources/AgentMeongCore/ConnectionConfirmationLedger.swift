import Foundation

public struct ConnectionConfirmation: Codable, Equatable, Sendable {
    public let instanceID: String
    public let definitionID: String?
    public let confirmedAt: Date

    public init(instanceID: String, definitionID: String?, confirmedAt: Date) {
        self.instanceID = instanceID
        self.definitionID = definitionID
        self.confirmedAt = confirmedAt
    }
}

/// Keeps a small, privacy-safe history per integration instance. Instance IDs
/// are opaque random identifiers; no CODEX_HOME or command path is stored.
public struct ConnectionConfirmationLedger: Codable, Equatable, Sendable {
    public static let maximumEntryCount = 16

    public private(set) var entries: [ConnectionConfirmation]

    public init(entries: [ConnectionConfirmation] = []) {
        self.entries = Self.normalized(entries)
    }

    public var latest: ConnectionConfirmation? {
        entries.max { lhs, rhs in
            if lhs.confirmedAt == rhs.confirmedAt {
                return lhs.instanceID < rhs.instanceID
            }
            return lhs.confirmedAt < rhs.confirmedAt
        }
    }

    public func confirmation(instanceID: String) -> ConnectionConfirmation? {
        guard !instanceID.isEmpty else { return nil }
        return entries.first { $0.instanceID == instanceID }
    }

    public func hasConfirmation(excluding instanceID: String?) -> Bool {
        entries.contains { $0.instanceID != instanceID }
    }

    public mutating func record(
        instanceID: String,
        definitionID: String?,
        at date: Date
    ) {
        guard !instanceID.isEmpty else { return }
        if let existing = entries.first(where: { $0.instanceID == instanceID }),
            existing.confirmedAt > date
        {
            return
        }
        entries.removeAll { $0.instanceID == instanceID }
        entries.append(ConnectionConfirmation(
            instanceID: instanceID,
            definitionID: definitionID,
            confirmedAt: date
        ))
        entries = Self.normalized(entries)
    }

    @discardableResult
    public mutating func remove(instanceID: String) -> Bool {
        let oldCount = entries.count
        entries.removeAll { $0.instanceID == instanceID }
        return entries.count != oldCount
    }

    public mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = Self.normalized(
            try container.decodeIfPresent([ConnectionConfirmation].self, forKey: .entries) ?? []
        )
    }

    private static func normalized(
        _ candidates: [ConnectionConfirmation]
    ) -> [ConnectionConfirmation] {
        var latestByInstance: [String: ConnectionConfirmation] = [:]
        for candidate in candidates where !candidate.instanceID.isEmpty {
            if let previous = latestByInstance[candidate.instanceID],
                previous.confirmedAt > candidate.confirmedAt
            {
                continue
            }
            latestByInstance[candidate.instanceID] = candidate
        }
        return latestByInstance.values.sorted { lhs, rhs in
            if lhs.confirmedAt == rhs.confirmedAt {
                return lhs.instanceID < rhs.instanceID
            }
            return lhs.confirmedAt < rhs.confirmedAt
        }.suffix(maximumEntryCount).map { $0 }
    }
}
