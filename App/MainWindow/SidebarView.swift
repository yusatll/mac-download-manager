import HDMCore
import SwiftUI

enum SidebarSelection: Hashable {
    case all(DownloadCategory?)
    case unfinished(DownloadCategory?)
    case finished(DownloadCategory?)
    case queues
    case mainQueue

    func includes(_ item: DownloadItem) -> Bool {
        switch self {
        case .all(let category): category == nil || item.category == category
        case .unfinished(let category): item.status != .completed && (category == nil || item.category == category)
        case .finished(let category): item.status == .completed && (category == nil || item.category == category)
        case .queues, .mainQueue: item.status == .queued
        }
    }
}

struct SidebarNode: Identifiable, Hashable {
    let id: SidebarSelection
    let title: String
    let symbol: String
    var children: [SidebarNode]?
}

struct SidebarView: View {
    @Binding var selection: SidebarSelection?

    private var nodes: [SidebarNode] {
        func categories(_ make: (DownloadCategory) -> SidebarSelection) -> [SidebarNode] {
            DownloadCategory.allCases.map { SidebarNode(id: make($0), title: $0.title, symbol: $0.symbol) }
        }
        return [
            SidebarNode(id: .all(nil), title: String(localized: "All Downloads"), symbol: "tray.full", children: categories { .all($0) }),
            SidebarNode(id: .unfinished(nil), title: String(localized: "Unfinished"), symbol: "arrow.down.circle", children: categories { .unfinished($0) }),
            SidebarNode(id: .finished(nil), title: String(localized: "Finished"), symbol: "checkmark.circle", children: categories { .finished($0) }),
            SidebarNode(id: .queues, title: String(localized: "Queues"), symbol: "list.number",
                        children: [SidebarNode(id: .mainQueue, title: String(localized: "Main Queue"), symbol: "list.bullet")]),
        ]
    }

    var body: some View {
        List(nodes, children: \.children, selection: $selection) { node in
            Label(node.title, systemImage: node.symbol)
        }
        .listStyle(.sidebar)
    }
}
