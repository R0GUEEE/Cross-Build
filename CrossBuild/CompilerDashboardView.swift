import SwiftUI

struct CompilerDashboardView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @ObservedObject var settings: AppSettings
    @State private var showManager = false
    @State private var showCatalog = false
    @State private var showConfiguration = false
    /// Computed off the render path: it walks the file tree and reads the
    /// Makefile, which must not happen every time the body is evaluated.
    @State private var buildItems: [WorkspaceModel.IndividualBuildItem] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(workspace.activeCompiler?.name ?? workspace.selectedToolchain.rawValue).font(.title2.bold())
                                    Text("Active toolchain").foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "cpu.fill").font(.largeTitle)
                            }
                            Picker("Toolchain", selection: $workspace.selectedToolchain) {
                                ForEach(ToolchainKind.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.menu)
                            HStack {
                                Button("Auto Detect", systemImage: "sparkle.magnifyingglass", action: workspace.detectSampleProject)
                                    .buttonStyle(.borderedProminent)
                                Button("Catalogue", systemImage: "square.grid.2x2") { showCatalog = true }.buttonStyle(.bordered)
                                Button("Custom", systemImage: "plus") { showManager = true }.buttonStyle(.bordered)
                                Button("Configure", systemImage: "slider.horizontal.3") { showConfiguration = true }.buttonStyle(.bordered)
                            }
                        }
                    }

                    if let analysis = workspace.analysis {
                        GroupBox("Project Detection") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    IDEStatusPill(icon: "cpu", text: analysis.primaryToolchain.rawValue)
                                    IDEStatusPill(icon: "chart.bar", text: "\(Int(analysis.confidence * 100))% confidence")
                                }
                                Text("Languages").font(.caption.bold())
                                Text(analysis.languages.map(\.rawValue).sorted().joined(separator: " • ")).foregroundStyle(.secondary)
                                Text("Build Systems").font(.caption.bold())
                                Text(analysis.buildSystems.map(\.rawValue).sorted().joined(separator: " • ")).foregroundStyle(.secondary)
                                if let type = analysis.theosType {
                                    Label("\(type.rawValue) • \(analysis.isRootlessHinted ? "Rootless" : "Scheme unspecified")",
                                          systemImage: "wrench.and.screwdriver")
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }

                        GroupBox("Build Plans") {
                            VStack(spacing: 8) {
                                ForEach(analysis.candidates) { candidate in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(candidate.system.rawValue).font(.headline)
                                            Text(candidate.reason).font(.caption).foregroundStyle(.secondary)
                                            Text(candidate.command).font(.system(.caption, design: .monospaced))
                                        }
                                        Spacer()
                                        Text("\(Int(candidate.confidence * 100))%").font(.caption.bold())
                                    }.padding(8).background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }

                    GroupBox("Target Summary") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("SDK", value: workspace.compilerConfiguration.sdk)
                            LabeledContent("Architecture", value: workspace.compilerConfiguration.architectures)
                            LabeledContent("Deployment", value: "iOS " + workspace.compilerConfiguration.deploymentTarget)
                            LabeledContent("Package", value: workspace.compilerConfiguration.packageFormat.uppercased())
                            LabeledContent("Signing", value: workspace.compilerConfiguration.signingMode)
                        }
                    }

                    GroupBox("App Toolchain Libraries") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Integrated", value: "\(AppToolchainLibraries.all.count)")
                            ForEach(AppToolchainLibraries.all.prefix(6)) { lib in
                                HStack {
                                    Image(systemName: AppToolchainLibraries.scanBundle().first { $0.id == lib.id }?.present == true ? "checkmark.seal.fill" : "exclamationmark.triangle")
                                    VStack(alignment: .leading) {
                                        Text(lib.name).font(.subheadline.weight(.medium))
                                        Text("\(lib.module) • \(lib.availability.rawValue)").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(lib.version).font(.caption2).monospaced()
                                }
                            }
                            if AppToolchainLibraries.all.count > 6 {
                                Button("View all \(AppToolchainLibraries.all.count) toolchains") { showCatalog = true }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Execution Backend") {
                        let backend = ExecutionBackendFactory.make(mode: "Embedded Runtime", settings: settings)
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Backend", value: backend.name)
                            LabeledContent("Status", value: workspace.executionStatus)
                            HStack {
                                IDEStatusPill(icon: "terminal", text: backend.capabilities.canSpawnProcesses ? "Process execution" : "No process spawn")
                                IDEStatusPill(icon: "network", text: backend.capabilities.canUseNetwork ? "Network" : "Offline")
                            }
                            HStack {
                                IDEStatusPill(icon: "folder", text: backend.capabilities.canAccessWorkspace ? "Workspace" : "No local workspace")
                                IDEStatusPill(icon: "shippingbox", text: backend.capabilities.canInstallPackages ? "Packages" : "No package install")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Build Actions") {
                        HStack {
                            action("Clean", "trash") { workspace.runWorkflowCommand(workspace.cleanCommand(), settings: settings) }
                            action("Build", "hammer.fill") { workspace.runBuild(settings: settings) }
                            action("Test", "checkmark.seal") { workspace.runWorkflowCommand(workspace.testCommand(), settings: settings) }
                            action("Package", "shippingbox.fill") { Task { _ = await workspace.runPackage(settings: settings) } }
                        }
                        RunProgressBar(progress: workspace.runProgress)
                            .padding(.top, 8)
                    }

                    GroupBox("Build Individual Items") {
                        VStack(alignment: .leading, spacing: 8) {
                            BuildStatusBar(progress: workspace.runProgress, last: workspace.lastRun)
                            Divider()
                            if buildItems.isEmpty {
                                Text("Open a source file, or add a Makefile, to build something on its own.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("The project build compiles everything. These compile one file or one make target, and copy it into the guest first — the guest has its own filesystem, so it cannot read the project until it is copied in.")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            } else {
                                ForEach(buildItems.prefix(10)) { item in
                                    Button {
                                        workspace.buildIndividual(item, settings: settings)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "hammer")
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(item.title).font(.subheadline)
                                                Text(item.detail).font(.caption2).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            individualResult(item)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(workspace.isExecuting)
                                }
                            }
                            HStack {
                                Button("Compile All Sources", systemImage: "square.stack.3d.down.right") {
                                    workspace.compileAllIndividualSources(settings: settings)
                                }
                                .font(.caption)
                                .disabled(workspace.isExecuting)
                                Button("Copy Workspace into Guest", systemImage: "arrow.down.to.line") {
                                    workspace.syncWorkspaceToGuest(settings: settings)
                                }
                                .font(.caption)
                                .disabled(workspace.isExecuting)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding()
            }
            .navigationTitle("Compiler")
            .toolbar { ToolbarItem(placement: .topBarLeading) { AppMenuButton(settings: settings) } }
            .task(id: workspace.files.roots.count) { buildItems = workspace.individualBuildItems() }
            .sheet(isPresented: $showManager) { CompilerManagerView().environmentObject(workspace) }
            .sheet(isPresented: $showCatalog) { CompilerCatalogView().environmentObject(workspace) }
            .sheet(isPresented: $showConfiguration) {
                NavigationStack { CompilerConfigurationView(config: workspace.compilerConfiguration) }
            }
        }
    }

    /// The last result for one item, so the list says which files compile rather
    /// than only offering a button that may already have failed.
    @ViewBuilder
    private func individualResult(_ item: WorkspaceModel.IndividualBuildItem) -> some View {
        if case .file(let relative) = item.kind, let record = workspace.individualResults[relative] {
            HStack(spacing: 4) {
                Image(systemName: record.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(record.succeeded ? .green : .red)
                Text(RunProgressBar.clock(record.seconds)).monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { VStack { Image(systemName: icon).font(.title2); Text(title).font(.caption) }.frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
            .disabled(workspace.isExecuting)
    }
}
