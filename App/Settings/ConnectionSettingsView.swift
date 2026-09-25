import SwiftUI

struct ConnectionSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.settings
        Form {
            Picker("Connections per download:", selection: $store.settings.maxConnections) {
                ForEach([1, 2, 4, 8, 16, 24, 32], id: \.self) { Text(verbatim: "\($0)").tag($0) }
            }
            Stepper(value: $store.settings.maxConcurrentDownloads, in: 1...10) {
                LabeledContent("Simultaneous downloads:", value: "\(store.settings.maxConcurrentDownloads)")
            }
            Toggle("Limit total download speed", isOn: Binding(
                get: { store.settings.globalSpeedLimit > 0 },
                set: { store.settings.globalSpeedLimit = $0 ? 1024 * 1024 : 0 }))
            if store.settings.globalSpeedLimit > 0 {
                TextField("Maximum speed (KB/s):", value: Binding(
                    get: { Int(store.settings.globalSpeedLimit / 1024) },
                    set: { store.settings.globalSpeedLimit = Int64(max(1, $0)) * 1024 }), format: .number)
            }
            Stepper(value: $store.settings.retryCount, in: 0...50) {
                LabeledContent("Retries per connection:", value: "\(store.settings.retryCount)")
            }
            Stepper(value: $store.settings.timeoutSeconds, in: 5...300, step: 5) {
                LabeledContent("Timeout (seconds):", value: "\(Int(store.settings.timeoutSeconds))")
            }
        }
        .formStyle(.grouped)
    }
}
