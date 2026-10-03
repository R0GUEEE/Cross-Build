import SwiftUI

struct IDEView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @State private var selection = "main.swift"
    @State private var showCompilerManager = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                WorkspaceBrowserView(files: workspace.files)
                Divider()
                HStack {
                    Button(action: workspace.detectSampleProject) {
                        Label("Detect", systemImage: "waveform.badge.magnifyingglass")
                    }
                    Spacer()
                    Button { showCompilerManager = true } label: {
                        Label("Compiler", systemImage: "cpu")
                    }
                }.padding(8)
            }
            .navigationTitle("Cross Build")
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Picker("Toolchain", selection: $workspace.selectedToolchain) {
                        ForEach(ToolchainKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                    Button("Build", systemImage: "hammer.fill", action: workspace.runBuild)
                        .buttonStyle(.borderedProminent)
                }
                .padding()

                if let analysis = workspace.analysis {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(analysis.primaryToolchain.rawValue, systemImage: "cpu")
                            Spacer()
                            Text("\(Int(analysis.confidence * 100))% confidence").foregroundStyle(.secondary)
                        }
                        Text(analysis.languages.map(\.rawValue).sorted().joined(separator: " • "))
                            .font(.caption).foregroundStyle(.secondary)
                        if let candidate = analysis.candidates.first {
                            Text("$ \(candidate.command)")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                Divider()
                TextEditor(text: $workspace.editorText)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                VStack(spacing: 8) {
                    ScrollView {
                        Text(workspace.console)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 120)

                    HStack {
                        TextField("Ask agent to build, fix, test, package…", text: $workspace.agentPrompt)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(workspace.runAgent)
                        Button("Run Agent", action: workspace.runAgent)
                    }
                }
                .padding()
                .background(.thinMaterial)
            }
            .navigationTitle(selection)
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showCompilerManager) {
            CompilerManagerView().environmentObject(workspace)
        }
    }
}
