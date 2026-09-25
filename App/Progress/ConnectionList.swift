import HDMCore
import SwiftUI

struct ConnectionList: View {
    let connections: [ConnectionInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("N.").frame(width: 30, alignment: .leading)
                Text("Downloaded").frame(width: 120, alignment: .leading)
                Text("Info")
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            ForEach(Array(connections.enumerated()), id: \.element.id) { offset, connection in
                HStack {
                    Text(verbatim: "\(offset + 1)").frame(width: 30, alignment: .leading)
                    Text(Format.bytes(connection.receivedInSegment)).frame(width: 120, alignment: .leading)
                    Text(connection.isReceiving ? "Receiving data…" : "Connecting…")
                }
                .font(.caption.monospacedDigit())
            }
            if connections.isEmpty {
                Text("No active connections").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
