import AppKit
import HDMCore
import SwiftUI

/// Opens AppKit-hosted SwiftUI windows (dialogs), one per key, from anywhere in the app.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    unowned let model: AppModel
    private var windows: [String: NSWindow] = [:]

    init(model: AppModel) {
        self.model = model
    }

    static func progressKey(_ id: UUID) -> String { "progress-\(id.uuidString)" }

    func show<Content: View>(key: String, title: String, @ViewBuilder content: () -> Content) {
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let root = content().environment(model).environment(model.manager)
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(key)
        window.delegate = self
        window.center()
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close(key: String) { windows[key]?.close() }
    func window(for key: String) -> NSWindow? { windows[key] }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let key = window.identifier?.rawValue else { return }
        windows[key] = nil
    }
}
