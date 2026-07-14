import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
let debugDock = ProcessInfo.processInfo.environment["AGENT_MEONG_DEBUG_DOCK"] == "1"
application.setActivationPolicy(debugDock ? .regular : .accessory)

withExtendedLifetime(delegate) {
    application.run()
}
