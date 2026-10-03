import SwiftUI

struct CompilerManagerView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var executable = ""
    @State private var arguments = ""
    @State private var buildCommand = ""
    @State private var cleanCommand = ""
    @State private var testCommand = ""
    @State private var packageCommand = ""
    @State private var markers = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Installed / Added Compilers") {
                    ForEach(workspace.customCompilers) { compiler in
                        Button {
                            workspace.selectedCustomCompilerID = compiler.id
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(compiler.name)
                                Text(compiler.executable).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if workspace.customCompilers.isEmpty {
                        Text("No custom compilers yet.").foregroundStyle(.secondary)
                    }
                }
                Section("Add Compiler") {
                    TextField("Name", text: $name)
                    TextField("Executable path", text: $executable)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Default arguments", text: $arguments)
                    TextField("Build command", text: $buildCommand)
                    TextField("Clean command", text: $cleanCommand)
                    TextField("Test command", text: $testCommand)
                    TextField("Package command", text: $packageCommand)
                    TextField("Detection markers (comma separated)", text: $markers)
                }
            }
            .navigationTitle("Compilers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        workspace.addCompiler(.init(
                            name: name.isEmpty ? "Custom Compiler" : name,
                            executable: executable,
                            arguments: arguments,
                            buildCommand: buildCommand.isEmpty ? executable + " " + arguments : buildCommand,
                            cleanCommand: cleanCommand,
                            testCommand: testCommand,
                            packageCommand: packageCommand,
                            detectionMarkers: markers
                        ))
                        dismiss()
                    }.disabled(executable.isEmpty)
                }
            }
        }
    }
}
