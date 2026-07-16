enum HookRemovalPolicy {
    static func shouldClearObservedConnection(
        hasObservedConnection: Bool,
        observedInstanceID: String?,
        removedInstanceID: String?
    ) -> Bool {
        guard hasObservedConnection else { return true }
        guard let observedInstanceID else { return false }
        return observedInstanceID == removedInstanceID
    }
}
