import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            SaveToSettingsView().tabItem { Label("Save To", systemImage: "folder") }
            ConnectionSettingsView().tabItem { Label("Connection", systemImage: "network") }
            VideoSettingsView().tabItem { Label("Video", systemImage: "film") }
            BrowserSettingsView().tabItem { Label("Browsers", systemImage: "safari") }
            ExceptionsSettingsView().tabItem { Label("Exceptions", systemImage: "hand.raised") }
        }
        .frame(width: 600, height: 520)
    }
}
