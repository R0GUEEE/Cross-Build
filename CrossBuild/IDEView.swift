import SwiftUI

struct IDEView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showCompilerManager = false
    @State private var showGitHub = false
    @State private var bottomPanel: ForgePanel = .terminal
    @State private var bottomExpanded = true

    var body: some View {
        NavigationSplitView {
            navigator
                .navigationTitle("Cross Build")
        } detail: {
            editorWorkspace
        }
        .sheet(isPresented: $showCompilerManager) {
            CompilerManagerView().environmentObject(workspace)
        }
        .sheet(isPresented: $showGitHub) {
            GitHubCloneView(github: workspace.github)
        }
    }

    private var navigator: some View {
        VStack(spacing: 0) {
            HStack {
                IDEStatusPill(icon: "folder.fill", text: "Workspace")
                Spacer()
                Menu {
                    Button("Auto Detect Compiler", systemImage: "waveform.badge.magnifyingglass", action: workspace.detectSampleProject)
                    Button("Manage Compilers", systemImage: "cpu") { showCompilerManager = true }
                    Button("Clone from GitHub", systemImage: "arrow.down.circle") { showGitHub = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }.padding(10)

            Divider()
            WorkspaceBrowserView(files: workspace.files)
        }
    }

    private var editorWorkspace: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            tabBar
            Divider()
            detectionBar
            editor
            Divider()
            if bottomExpanded {
                BottomWorkbenchView(panel: $bottomPanel)
                    .environmentObject(workspace)
                    .frame(height: sizeClass == .compact ? 210 : 260)
            } else {
                collapsedPanelBar
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Cross Build").font(.headline)
                Text("Portable Compiler Workbench").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Picker("Toolchain", selection: $workspace.selectedToolchain) {
                    ForEach(ToolchainKind.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Button("Manage Compilers", systemImage: "slider.horizontal.3") { showCompilerManager = true }
                Button("Auto Detect", systemImage: "sparkle.magnifyingglass", action: workspace.detectSampleProject)
            } label: {
                IDEStatusPill(icon: "cpu", text: workspace.activeCompiler?.name ?? workspace.selectedToolchain.rawValue)
            }
            Button(action: workspace.runBuild) {
                Label("Build", systemImage: "play.fill").font(.subheadline.weight(.semibold))
            }.buttonStyle(.borderedProminent)
        }.padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                editorTab("main.swift", icon: "swift", selected: true)
                editorTab("Makefile", icon: "hammer", selected: false)
                editorTab("control", icon: "shippingbox", selected: false)
                Button { workspace.files.createFile(named: "Untitled.swift") } label: {
                    Image(systemName: "plus").padding(8)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 8).padding(.vertical, 5)
        }.background(.secondary.opacity(0.04))
    }

    private func editorTab(_ title: String, icon: String, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title)
            if selected { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary) }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: ForgeTheme.compactCorner)
                .fill(selected ? Color.secondary.opacity(0.12) : Color.clear)
        )
    }

    @ViewBuilder private var detectionBar: some View {
        if let analysis = workspace.analysis {
            HStack(spacing: 8) {
                IDEStatusPill(icon: "cpu", text: analysis.primaryToolchain.rawValue)
                IDEStatusPill(icon: "chart.bar.fill", text: "\(Int(analysis.confidence * 100))%")
                if let type = analysis.theosType { IDEStatusPill(icon: "wrench.and.screwdriver", text: type.rawValue) }
                Spacer()
                if let candidate = analysis.candidates.first {
                    Text(candidate.command).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 10).padding(.vertical, 6).background(.secondary.opacity(0.04))
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $workspace.editorText)
                .font(.system(size: sizeClass == .compact ? 14 : 15, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.leading, sizeClass == .compact ? 2 : 36)
            if sizeClass != .compact {
                Text("1\n2\n3\n4\n5\n6\n7\n8\n9\n10")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 8)
                    .allowsHitTesting(false)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var collapsedPanelBar: some View {
        HStack {
            ForEach(ForgePanel.allCases) { item in
                Button {
                    bottomPanel = item; bottomExpanded = true
                } label: { Label(item.rawValue, systemImage: item.icon).font(.caption) }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { bottomExpanded = true } label: { Image(systemName: "chevron.up") }
        }.padding(8)
    }
}
