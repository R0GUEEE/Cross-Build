import SwiftUI

@main
struct CrossBuildApp: App {
    @StateObject private var workspace = WorkspaceModel()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView(settings: settings)
                .environmentObject(workspace)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings
    @State private var section: AppSection = .workspace

    var body: some View {
        TabView(selection: $section) {
            IDEView(settings: settings)
                .tabItem { Label("Workspace", systemImage: AppSection.workspace.icon) }
                .tag(AppSection.workspace)

            CompilerDashboardView()
                .tabItem { Label("Compiler", systemImage: AppSection.compiler.icon) }
                .tag(AppSection.compiler)

            AgentDashboardView(settings: settings)
                .tabItem { Label("Agent", systemImage: AppSection.agent.icon) }
                .tag(AppSection.agent)

            SettingsView(settings: settings)
                .tabItem { Label("Settings", systemImage: AppSection.settings.icon) }
                .tag(AppSection.settings)
        }
    }
}
