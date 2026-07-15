import Foundation

/// A privacy-minimized restart checkpoint. It contains only the derived actor
/// metadata already allowed by the observation protocol and never raw events.
public struct WorldCheckpoint: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let actors: [ActorState]

    public init(state: WorldState) {
        schemaVersion = Self.currentSchemaVersion
        actors = state.orderedActors.filter { actor in
            switch actor.visualState {
            case .active, .attention, .uncertain:
                true
            case .quiet, .completed, .cancelled, .failed:
                false
            }
        }
    }

    public init(schemaVersion: Int, actors: [ActorState]) {
        self.schemaVersion = schemaVersion
        self.actors = actors
    }
}
