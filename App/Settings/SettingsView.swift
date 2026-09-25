import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            SaveToSettingsView().tabItem { Label("Save To", systemImage: "folder") }
            ConnectionSettingsView().tabItem { Label("Connection", systemImage: "network") }
        }
        .frame(width: 600, height: 520)
    }
}
