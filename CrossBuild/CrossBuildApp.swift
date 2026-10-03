import SwiftUI

@main
struct CrossBuildApp: App {
    @StateObject private var workspace = WorkspaceModel()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView(settings: settings)
                .environmentObject(workspace)
                .task {
                    workspace.appSettings = settings
                    workspace.syncFileConfiguration()

                    // The visible file tree is built off the main actor, so wait
                    // for the first pass before doing anything that reads it.
                    // `projectFiles` derives from that tree, and an empty one would
                    // silently skip project detection at launch.
                    await workspace.files.waitForTree()
                    if settings.autoDetect && !workspace.projectFiles.isEmpty { workspace.detectSampleProject() }

                    // Start the Linux guest as soon as the app opens when it is the
                    // selected backend. Booting an emulated kernel takes real time,
                    // so doing it here rather than on the first command means the
                    // root is already up by the time anything asks to run.
                    if settings.executionBackend == "Linux Guest" {
                        await LinuxGuestSession.shared.startIfNeeded()
                    }
                }
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

            CompilerDashboardView(settings: settings)
                .tabItem { Label("Compiler", systemImage: AppSection.compiler.icon) }
                .tag(AppSection.compiler)

            AgentDashboardView(settings: settings)
                .tabItem { Label("Agent", systemImage: AppSection.agent.icon) }
                .tag(AppSection.agent)

            SettingsView(settings: settings)
                .tabItem { Label("Settings", systemImage: AppSection.settings.icon) }
                .tag(AppSection.settings)
        }
        .alert("Allow Agent Commands?", isPresented: Binding(
            get: { workspace.pendingAgentConfirmation != nil },
            set: { if !$0 { workspace.pendingAgentPlanDismissed() } }
        )) {
            Button("Run Commands") { workspace.confirmPendingAgentPlan() }
            Button("Cancel", role: .cancel) { workspace.cancelPendingAgentPlan() }
        } message: {
            Text(workspace.pendingAgentConfirmation ?? "")
        }
    }
}
