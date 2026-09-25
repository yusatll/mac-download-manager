import Foundation
import Observation

@MainActor @Observable
public final class SettingsStore {
    private var stored: AppSettings
    @ObservationIgnored public var onChange: ((AppSettings) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "HDM.settings.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            stored = decoded
        } else {
            stored = AppSettings()
        }
    }

    public var settings: AppSettings {
        get { stored }
        set {
            guard newValue != stored else { return }
            stored = newValue
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key) }
            onChange?(newValue)
        }
    }
}
