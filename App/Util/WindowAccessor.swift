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

/// Resizes an AppKit-hosted window to its SwiftUI content when `trigger` changes. Runs after the
/// current layout pass, so it avoids the constraint-loop crash that live `preferredContentSize` caused.
struct FitWindowToContent<Trigger: Equatable>: View {
    let trigger: Trigger
    var body: some View {
        WindowAccessor { window in
            guard let view = window.contentViewController?.view else { return }
            let size = view.fittingSize
            if window.contentLayoutRect.size != size { window.setContentSize(size) }
        }
        .id(AnyHashable(String(describing: trigger)))
        .frame(width: 0, height: 0)
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
