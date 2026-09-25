import HDMCore
import SwiftUI

extension DownloadItem {
    var sortableSize: Int64 { totalBytes ?? -1 }
    var sortableLastTry: Date { lastTryAt ?? .distantPast }
}

struct DownloadTable: View {
    @Environment(DownloadManager.self) private var manager
    let filter: SidebarSelection
    let search: String
    @Binding var selection: Set<UUID>
    @State private var sortOrder = [KeyPathComparator(\DownloadItem.createdAt)]

    private var rows: [DownloadItem] {
        manager.items
            .filter { filter.includes($0) && (search.isEmpty || $0.fileName.localizedCaseInsensitiveContains(search)) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("File Name", value: \.fileName) { item in
                HStack(spacing: 6) {
                    Image(nsImage: FileIcon.icon(for: item.fileName)).resizable().frame(width: 16, height: 16)
                    Text(item.fileName).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 200, ideal: 320)
            TableColumn("Size", value: \.sortableSize) { item in
                Text(Format.bytes(item.totalBytes)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Status") { item in
                StatusCell(item: item)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Time Left") { item in
                Text(item.status == .downloading ? Format.duration(manager.live[item.id]?.secondsRemaining) : "").monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Transfer Rate") { item in
                Text(Format.speed(manager.live[item.id]?.bytesPerSecond ?? 0)).monospacedDigit()
            }
            .width(min: 80, ideal: 100)
            TableColumn("Last Try", value: \.sortableLastTry) { item in
                Text(Format.date(item.lastTryAt))
            }
            .width(min: 120, ideal: 150)
            TableColumn("Description", value: \.userDescription)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            ItemContextMenu(ids: ids)
        }
    }
}

struct StatusCell: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.status.text(fraction: item.fractionCompleted)).lineLimit(1)
            if item.status == .downloading || item.status == .paused, let fraction = item.fractionCompleted {
                ProgressView(value: fraction).controlSize(.mini)
            }
        }
    }
}
