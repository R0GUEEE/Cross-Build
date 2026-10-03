import SwiftUI

struct CompilerDashboardView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @State private var showManager = false

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
                                Button("Add Compiler", systemImage: "plus") { showManager = true }.buttonStyle(.bordered)
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

                    GroupBox("Build Actions") {
                        HStack {
                            action("Clean", "trash") { workspace.console += "$ clean\n" }
                            action("Build", "hammer.fill", workspace.runBuild)
                            action("Test", "checkmark.seal") { workspace.console += "$ test\n" }
                            action("Package", "shippingbox.fill") { workspace.console += "$ package\n" }
                        }
                    }
                }.padding()
            }
            .navigationTitle("Compiler")
            .sheet(isPresented: $showManager) { CompilerManagerView().environmentObject(workspace) }
        }
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { VStack { Image(systemName: icon).font(.title2); Text(title).font(.caption) }.frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
    }
}
