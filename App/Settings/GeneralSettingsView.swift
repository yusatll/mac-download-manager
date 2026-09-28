import AppKit
import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var captureText = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var store = model.settings
        Form {
            Section("Capture") {
                Toggle("Watch the clipboard for download links", isOn: $store.settings.clipboardMonitoring)
                Toggle("Start downloads without showing the Download File Info dialog", isOn: $store.settings.startWithoutDialog)
                LabeledContent("File types to capture:") {
                    TextField("", text: $captureText, axis: .vertical).lineLimit(3...6)
                }
            }
            Section("Windows") {
                Toggle("Show the download progress window", isOn: $store.settings.showProgressWindow)
                Toggle("Show the download complete dialog", isOn: $store.settings.showCompletionDialog)
                Toggle("Keep MacDM in the menu bar", isOn: $store.settings.keepInMenuBar)
            }
            Section("System") {
                Toggle("Launch MacDM when I log in", isOn: $launchAtLogin)
                Toggle("Prevent sleep while downloading", isOn: $store.settings.preventSleep)
            }
        }
        .formStyle(.grouped)
        .onAppear { captureText = model.settings.settings.captureExtensions.joined(separator: " ") }
        .onChange(of: captureText) { _, new in model.settings.settings.captureExtensions = Self.parseExtensions(new) }
        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
    }

    static func parseExtensions(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = String(localized: "Could not change the login item")
            alert.runModal()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
