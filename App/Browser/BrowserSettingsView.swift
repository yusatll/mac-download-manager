import SafariServices
import SwiftUI

/// Settings > Browsers (spec §6.6): per-browser connection state, install pointers and a
/// "rebuild the bridge manifests" action.
struct BrowserSettingsView: View {
    @Environment(AppModel.self) private var model

    private static let knownBrowsers: [(key: String, title: String)] = [
        ("chrome", "Chrome"),
        ("brave", "Brave"),
        ("edge", "Edge"),
        ("vivaldi", "Vivaldi"),
        ("chromium", "Chromium"),
        ("safari", "Safari"),
    ]

    var body: some View {
        Form {
            Section("Connection") {
                ForEach(Self.knownBrowsers, id: \.key) { browser in
                    LabeledContent(browser.title) {
                        if let seen = model.browser.lastSeen[browser.key] {
                            Text(String(localized: "Connected — last seen \(seen.formatted(date: .omitted, time: .standard))"))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not seen yet").foregroundStyle(.tertiary)
                        }
                    }
                }
                Button("Rebuild Browser Connection") {
                    NativeMessagingManifest.writeAll()
                }
            }
            Section("Install the extension") {
                LabeledContent("Chrome / Brave / Edge / Vivaldi") {
                    Text("Load “Extension/dist/macdm-chrome” as an unpacked extension (chrome://extensions → Developer mode).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                LabeledContent("Safari") {
                    HStack {
                        Button("Enable in Safari…") {
                            SFSafariApplication.showPreferencesForExtension(
                                withIdentifier: "com.macdm.MacDM.SafariExtension") { _ in }
                        }
                        Text("Safari → Settings → Extensions")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings > Exceptions (spec §6.6): wildcard site list + minimum capture size.
struct ExceptionsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var patternsText = ""

    var body: some View {
        @Bindable var store = model.settings
        Form {
            Section("Never capture from these sites") {
                TextField("", text: $patternsText, axis: .vertical).lineLimit(3...6)
                    .font(.system(.body, design: .monospaced))
                Text("One pattern per line or space-separated, e.g. *.apple.com or cdn.example.com")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Minimum size") {
                Picker("Skip downloads smaller than:", selection: $store.settings.minimumCaptureSizeBytes) {
                    Text("No minimum").tag(Int64(0))
                    Text("1 MB").tag(Int64(1 << 20))
                    Text("5 MB").tag(Int64(5 << 20))
                    Text("10 MB").tag(Int64(10 << 20))
                }
                Text("Smaller downloads stay in the browser.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Video panel") {
                Toggle("Show the “Download this video” button on video pages", isOn: $store.settings.videoPanelEnabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { patternsText = model.settings.settings.exceptionPatterns.joined(separator: "\n") }
        .onChange(of: patternsText) { _, new in
            model.settings.settings.exceptionPatterns = new
                .split(whereSeparator: { $0.isNewline || $0 == " " })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }
}
