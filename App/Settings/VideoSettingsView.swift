import HDMCore
import SwiftUI

/// Settings > Video (spec §6.6): format preference and the state of the helper programs
/// yt-dlp, ffmpeg and deno (version, location, refresh).
struct VideoSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var statuses: [ComponentStatus] = []
    @State private var loading = true

    var body: some View {
        @Bindable var store = model.settings
        Form {
            Section("Formats") {
                Toggle("Prefer QuickTime-compatible formats (H.264/AAC)", isOn: $store.settings.preferQuickTimeCompatible)
            }
            Section("Helper programs") {
                if loading {
                    HStack { ProgressView().controlSize(.small); Text("Checking…") }
                }
                ForEach(statuses) { status in
                    LabeledContent(status.name) {
                        VStack(alignment: .trailing, spacing: 2) {
                            if status.found {
                                Text(status.version ?? "Found").foregroundStyle(.secondary)
                                Text(status.path?.path ?? "").font(.caption).foregroundStyle(.tertiary)
                            } else {
                                Label("Not found", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                Text("brew install \(status.name)").font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                }
                Button("Check Again") { Task { await reload() } }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        statuses = await ComponentLocator.status()
        loading = false
    }
}
