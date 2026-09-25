import Foundation

/// Keeps the Mac awake while downloads run (spec §6.4).
@MainActor
final class SleepGuard {
    private var activity: NSObjectProtocol?

    func update(active: Bool) {
        if active, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Downloading files")
        } else if !active, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }
}
