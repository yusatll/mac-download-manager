import AppKit
import SafariServices
import ServiceManagement
import SwiftUI

/// First-launch window (spec §6.7): browser extension pointers, Safari enable button,
/// clipboard note and the login-item offer.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Welcome to MacDM", systemImage: "arrow.down.circle.fill").font(.title2).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 12) {
                step(number: 1, title: String(localized: "Chrome / Brave / Edge / Vivaldi")) {
                    Text("Install the MacDM extension: open chrome://extensions, enable Developer mode and load the “Extension/dist/macdm-chrome” folder from the repository (Web Store listing coming soon).")
                    Text("MacDM registers its browser connection automatically when it runs.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                step(number: 2, title: String(localized: "Safari")) {
                    Text("Enable MacDM in Safari → Settings → Extensions.")
                    Button("Enable in Safari…") { enableSafari() }
                }
                step(number: 3, title: String(localized: "Clipboard")) {
                    Text("Copy a file or video link anywhere and MacDM offers to download it. You can turn this off in Settings → General.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Divider()
            Toggle("Launch MacDM when I log in", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    _ = try? (enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister())
                }
            HStack {
                Spacer()
                Button("Start Using MacDM") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func step(number: Int, title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.callout.bold()).frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.semibold)
                content()
            }
        }
    }

    private func enableSafari() {
        SFSafariApplication.showPreferencesForExtension(
            withIdentifier: "com.macdm.MacDM.SafariExtension") { error in
            if let error { NSLog("MacDM: could not open Safari extension settings: \(error)") }
        }
    }
}
