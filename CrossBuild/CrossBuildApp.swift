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
                    LinuxGuestSession.shared.configure(initCommand: settings.shellInitCommand)
                    await LinuxGuestSession.shared.startIfNeeded()

                    // Ask the guest what it carries before any screen needs the
                    // answer. The probe used to run only from a build action or
                    // from Setup, so until one of those had happened every
                    // toolchain read as undetected on the Compiler tab, in the
                    // catalogue and on the components screen.
                    await workspace.probeGuestToolchain()
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings
    @State private var section: AppSection = .workspace

    var body: some View {
        // A fixed application shell: menu bar, content, tab bar.
        //
        // This used to be a `TabView`, which on iPad reshapes its own bar as the
        // content scrolls -- the window appearing to change size under your
        // finger rather than the app navigating. Fixed heights and a plain switch
        // mean the chrome is the same shape on every device and every scroll
        // position.
        VStack(spacing: 0) {
            Group {
                switch section {
                case .workspace: IDEView(settings: settings)
                case .compiler: CompilerDashboardView(settings: settings)
                case .agent: AgentDashboardView(settings: settings)
                case .settings: SettingsView(settings: settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            RootTabBar(section: $section)
        }
        .background(ForgeTheme.Surface.background)
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

/// The app's menus, as a menu in the navigation bar.
///
/// This is where iOS puts them. A strip of menus across the top of the window is
/// desktop chrome: it costs a permanent row of height, it competes with the tab
/// bar for meaning, and it is the one piece of a phone app that tells the user
/// they are looking at a ported program rather than an app.
///
/// Every entry acts on the workspace model directly, so the menu needs no view
/// state of its own and cannot get out of step with the screen behind it.
struct AppMenuButton: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var workspace: WorkspaceModel

    var body: some View {
        Menu {
            Section("Project") {
                Button("Refresh Files", systemImage: "arrow.clockwise") { workspace.files.reload() }
                Button("Detect Project & Compiler", systemImage: "waveform.badge.magnifyingglass") { workspace.detectSampleProject() }
                Button("Save Current File", systemImage: "square.and.arrow.down") { workspace.saveEditor() }
            }
            Section("Build") {
                Button("Build Project", systemImage: "hammer.fill") { workspace.runBuild(settings: settings) }
                if let document = workspace.editor.selected {
                    Button("Build \(document.name)", systemImage: "doc.badge.gearshape") {
                        workspace.buildIndividual(.init(kind: .file(workspace.relativePath(document.path)),
                                                        title: document.name,
                                                        detail: "Compile this file on its own"),
                                                  settings: settings)
                    }
                }
                Button("Compile All Sources", systemImage: "square.stack.3d.down.right") {
                    workspace.compileAllIndividualSources(settings: settings)
                }
                Divider()
                Button("Clean", systemImage: "trash") { workspace.runWorkflowCommand(workspace.cleanCommand(), settings: settings) }
                Button("Test", systemImage: "checkmark.seal") { workspace.runWorkflowCommand(workspace.testCommand(), settings: settings) }
                Button("Package", systemImage: "shippingbox.fill") { Task { _ = await workspace.runPackage(settings: settings) } }
                Divider()
                Button("Copy Workspace into Guest", systemImage: "arrow.down.to.line") {
                    workspace.syncWorkspaceToGuest(settings: settings)
                }
            }
            Section("View") {
                Toggle("Word Wrap", isOn: $settings.editorWordWrap)
                Toggle("Line Numbers", isOn: $settings.editorLineNumbers)
                Toggle("Highlight Current Line", isOn: $settings.editorHighlightCurrentLine)
                Toggle("Show Invisible Characters", isOn: $settings.editorShowInvisibles)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

/// The tab bar. A plain row -- it is chrome, so it should not move or resize
/// with the content -- but built like a system one: scaled to the user's text
/// size, filled symbols when selected, and a real tap target per item.
private struct RootTabBar: View {
    @Binding var section: AppSection
    /// Scales with Dynamic Type, so a large text setting grows the bar instead of
    /// clipping the labels. The old bar was a fixed 49pt with 10pt text.
    @ScaledMetric(relativeTo: .caption2) private var barHeight: CGFloat = 49

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppSection.allCases) { item in
                let isSelected = section == item
                Button {
                    section = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                            .symbolVariant(isSelected ? .fill : .none)
                            .imageScale(.large)
                        Text(item.rawValue)
                            .font(.caption2.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: barHeight)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        // The standard iOS tab bar proportions, with the system's own material
        // so it blurs the content behind it rather than sitting on top as a slab.
        .frame(minHeight: barHeight)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.easeOut(duration: 0.18), value: section)
    }
}
