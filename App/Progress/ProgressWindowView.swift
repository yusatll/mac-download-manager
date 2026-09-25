import HDMCore
import SwiftUI

/// IDM's per-download status window (spec §6.3).
struct ProgressWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(DownloadManager.self) private var manager
    let id: UUID
    @State private var tab = 0
    @State private var showDetails = false

    var body: some View {
        if let item = manager.item(id) {
            content(item)
                .background(WindowTitle(title: title(item)))
                .background(FitWindowToContent(trigger: "\(tab)-\(showDetails)"))
        } else {
            Text("This download was removed.").padding(40)
        }
    }

    private func title(_ item: DownloadItem) -> String {
        guard let fraction = item.fractionCompleted else { return item.fileName }
        return "\(Int((fraction * 100).rounded(.down)))% \(item.fileName)"
    }

    private func content(_ item: DownloadItem) -> some View {
        let stats = manager.live[id]
        return VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                Text("Download status").tag(0)
                Text("Speed Limiter").tag(1)
                Text("Options on completion").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case 0: statusTab(item, stats)
            case 1: SpeedLimitTab(item: item)
            default: CompletionOptionsTab(item: item)
            }

            HStack {
                if tab == 0 {
                    Button(showDetails ? "Hide details" : "Show details") { showDetails.toggle() }
                }
                Spacer()
                if item.status.isRunning || item.status == .queued {
                    Button("Pause") { model.stop([id]) }
                } else if item.status.canResume {
                    Button("Resume") { manager.resume([id]) }
                }
                Button("Cancel") {
                    if item.status.isRunning || item.status == .queued { model.stop([id]) }
                    model.windows.close(key: WindowCoordinator.progressKey(id))
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 580)
    }

    private func statusTab(_ item: DownloadItem, _ stats: LiveStats?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.url.absoluteString).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Status:", statusLine(item))
                row("File size:", item.totalBytes.map { Format.bytes($0) } ?? String(localized: "Unknown"))
                row("Downloaded:", downloaded(item))
                row("Transfer rate:", Format.speed(stats?.bytesPerSecond ?? 0))
                row("Time left:", Format.duration(stats?.secondsRemaining))
                row("Resume capability:", resumeText(item))
            }
            ProgressView(value: item.fractionCompleted ?? 0)
            SegmentBar(segments: item.segments, total: item.totalBytes,
                       activeSegments: Set(stats?.connections.map(\.segmentIndex) ?? []))
                .frame(height: 14)
            if showDetails {
                ConnectionList(connections: stats?.connections ?? [])
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).monospacedDigit()
        }
    }

    private func statusLine(_ item: DownloadItem) -> String {
        if case .failed(let reason) = item.status { return reason.message }
        return item.status.text(fraction: item.fractionCompleted)
    }

    private func downloaded(_ item: DownloadItem) -> String {
        let bytes = Format.bytes(item.receivedBytes)
        guard let fraction = item.fractionCompleted else { return bytes }
        return "\(bytes) (\(Format.percent(fraction)))"
    }

    private func resumeText(_ item: DownloadItem) -> String {
        switch item.resumable {
        case true?: String(localized: "Yes")
        case false?: String(localized: "No")
        case nil: String(localized: "Unknown")
        }
    }
}
