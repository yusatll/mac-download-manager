import AppKit
import SwiftUI

/// Gives SwiftUI content access to its hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
    let configure: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let configure = configure
        Task { @MainActor in
            if let window = view.window { configure(window) }
        }
    }
}

/// Keeps the hosting window's title in sync (used by AppKit-hosted windows).
struct WindowTitle: View {
    let title: String
    var body: some View {
        WindowAccessor { window in
            if window.title != title { window.title = title }
        }
        .frame(width: 0, height: 0)
    }
}
