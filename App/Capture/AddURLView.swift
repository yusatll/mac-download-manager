import AppKit
import SwiftUI

struct AddURLView: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    @State private var address = AddURLView.clipboardLink() ?? ""
    @State private var useAuthorization = false
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                TextField("Address:", text: $address)
                Toggle("Use authorization", isOn: $useAuthorization)
                if useAuthorization {
                    TextField("User name:", text: $user)
                    SecureField("Password:", text: $password)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("OK") { submit() }.keyboardShortcut(.defaultAction).disabled(parsedURL == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var parsedURL: URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    private func submit() {
        guard let url = parsedURL else { return }
        var headers: [String: String] = [:]
        if useAuthorization, !user.isEmpty {
            headers["Authorization"] = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        }
        close()
        model.capture.handle(PendingDownload(url: url, headers: headers, source: .manual))
    }

    /// The user opened this window themselves, so reading the clipboard here is user-initiated.
    private static func clipboardLink() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return text
    }
}
