import HDMCore
import SwiftUI

struct CompletionView: View {
    @Environment(AppModel.self) private var model
    let item: DownloadItem
    let close: () -> Void
    @State private var dontShowAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: FileIcon.icon(for: item.fileName)).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download complete").font(.headline)
                    Text(item.fileName).lineLimit(1).truncationMode(.middle)
                    Text(Format.bytes(item.totalBytes)).foregroundStyle(.secondary)
                }
            }
            Text(item.fileURL.path(percentEncoded: false)).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            Toggle("Don't show this dialog again", isOn: $dontShowAgain)
            HStack {
                Button("Open") { model.open(item); done() }.keyboardShortcut(.defaultAction)
                Button("Open With…") { model.openWith(item); done() }
                Button("Open Folder") { model.reveal(item); done() }
                Spacer()
                Button("Close") { done() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func done() {
        if dontShowAgain { model.settings.settings.showCompletionDialog = false }
        close()
    }
}
