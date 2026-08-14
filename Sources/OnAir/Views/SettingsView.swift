import SwiftUI

struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        TabView {
            SlackPane(coordinator: coordinator)
                .tabItem { Label("Slack", systemImage: "link") }
            StatusPane(coordinator: coordinator)
                .tabItem { Label("Status", systemImage: "face.smiling") }
            BehaviourPane(coordinator: coordinator)
                .tabItem { Label("Behaviour", systemImage: "slider.horizontal.3") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: OnAirMetrics.settingsWidth)
        .padding(OnAirMetrics.padding)
    }
}
