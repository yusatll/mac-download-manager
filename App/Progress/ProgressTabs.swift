import HDMCore
import SwiftUI

struct SpeedLimitTab: View {
    @Environment(DownloadManager.self) private var manager
    let item: DownloadItem
    @State private var enabled = false
    @State private var kilobytes = 500

    var body: some View {
        Form {
            Toggle("Use speed limiter", isOn: $enabled)
            TextField("Maximum download speed (KB/s):", value: $kilobytes, format: .number).disabled(!enabled)
        }
        .onAppear {
            enabled = item.speedLimit != nil
            kilobytes = Int((item.speedLimit ?? 512_000) / 1024)
        }
        .onChange(of: enabled) { apply() }
        .onChange(of: kilobytes) { apply() }
    }

    private func apply() {
        manager.setSpeedLimit(item.id, bytesPerSecond: enabled ? Int64(max(1, kilobytes)) * 1024 : nil)
    }
}

struct CompletionOptionsTab: View {
    @Environment(DownloadManager.self) private var manager
    let item: DownloadItem

    var body: some View {
        Form {
            Picker("When the download finishes:", selection: Binding(get: { item.onComplete }, set: { manager.setOnComplete(item.id, $0) })) {
                Text("Do nothing").tag(CompletionAction.nothing)
                Text("Open the file").tag(CompletionAction.open)
                Text("Show in Finder").tag(CompletionAction.revealInFinder)
            }
            .pickerStyle(.radioGroup)
        }
    }
}
